import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../services/valhalla_service.dart';

/// ─── RoutingController ───────────────────────────────────────────────────────
///
/// Owns everything related to the active route and its geometry.
/// Has zero knowledge of step progression or voice guidance — that belongs
/// in GuidanceController.
///
/// Responsibilities:
///   - Fetch a route from Valhalla (initial + reroute)
///   - Hold the active ValhallaRoute and expose it reactively
///   - Receive GPS ticks via [onLocationUpdate] and measure deviation
///   - Trigger a reroute when deviation exceeds a dynamic threshold
///     that accounts for whether the user is heading in the right direction
///
/// Does NOT:
///   - Know about navigation steps or turn announcements
///   - Hold a reference to LocationController (position is pushed in)
///   - Manage location permissions or GPS streams
///
/// How controllers relate:
///   LocationController → pushes ll.LatLng into onLocationUpdate()
///   RoutingController  → notifies GuidanceController via ChangeNotifier
///   GuidanceController → reads currentRoute to drive step progression
/// ─────────────────────────────────────────────────────────────────────────────

enum RoutingStatus {
  idle, // No route loaded
  fetching, // Initial route request in flight
  active, // Route loaded, user is on route
  rerouting, // User deviated, new route request in flight
  arrived, // User reached destination
  error, // Route fetch failed
}

class RoutingController extends ChangeNotifier {
  final String _valhallaBaseUrl;

  // ── Config ────────────────────────────────────────────────

  /// Base deviation threshold in meters. Used as the default when no
  /// heading information is available, and as the anchor for the dynamic
  /// threshold computation below.
  final double deviationThresholdMeters;

  /// How long the user must stay off-route before reroute triggers.
  /// Kept for API compatibility; the tick-count threshold below is what
  /// actually gates rerouting.
  final Duration deviationDebounce;

  /// Valhalla costing model — e.g. 'pedestrian', 'auto', 'bicycle'
  final String costing;

  // ── State ─────────────────────────────────────────────────
  ValhallaRoute? _currentRoute;
  RoutingStatus _status = RoutingStatus.idle;
  String? _errorMessage;
  ll.LatLng? _destination;

  // ── Deviation tracking ────────────────────────────────────
  double? _lastDeviation;

  /// Bearing of the route segment nearest to the user's last known position.
  /// Cached so the screen can read it without re-walking the polyline.
  double? _lastRouteBearing;

  int _deviationTickCount = 0;
  static const int _deviationTickThreshold = 3; // 3 consecutive off-route ticks

  RoutingController({
    required String valhallaBaseUrl,
    this.deviationThresholdMeters = 20.0,
    this.deviationDebounce = const Duration(seconds: 3),
    this.costing = 'pedestrian',
  }) : _valhallaBaseUrl = valhallaBaseUrl;

  // ── Public state ──────────────────────────────────────────
  ValhallaRoute? get currentRoute => _currentRoute;
  RoutingStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get hasRoute => _currentRoute != null;
  bool get isRerouting => _status == RoutingStatus.rerouting;
  double? get lastDeviation => _lastDeviation;

  /// Bearing (degrees, 0–360) of the route segment nearest to the user's
  /// last position. Null if no route is active or the polyline has fewer
  /// than two points. The screen reads this to compute heading alignment
  /// without duplicating the polyline walk.
  double? get lastRouteBearingAtUser => _lastRouteBearing;

  // ── Route fetching ────────────────────────────────────────

  /// Fetch an initial route from [origin] to [destination].
  /// Stores the destination so reroutes can reuse it automatically.
  /// Notifies listeners with status transitions: fetching → active | error.
  Future<void> fetchRoute(ll.LatLng origin, ll.LatLng destination) async {
    _destination = destination;
    _setStatus(RoutingStatus.fetching);

    final route = await getValhallaRoute(
      valhallaBaseUrl: _valhallaBaseUrl,
      origin: origin,
      destination: destination,
      costing: costing,
    );

    if (route == null) {
      _setStatus(RoutingStatus.error, error: 'Failed to fetch route');
      return;
    }

    _applyRoute(route);
  }

  /// Clear the active route and reset all state back to idle.
  void clearRoute() {
    _currentRoute = null;
    _destination = null;
    _deviationTickCount = 0;
    _lastRouteBearing = null;
    _setStatus(RoutingStatus.idle);
  }

  // ── Location updates ──────────────────────────────────────

  /// Called on every GPS tick from LocationController (via the navigation
  /// screen). Measures how far the user is from the route and triggers a
  /// reroute if they've been off-route for enough consecutive ticks.
  ///
  /// [userHeadingDegrees] is the compass heading. When provided, the reroute
  /// threshold becomes dynamic — a user walking parallel to the path is
  /// allowed to drift further than a user walking perpendicular or backward.
  /// This prevents false-positive reroutes on sidewalks that run alongside
  /// the mapped path.
  ///
  /// Returns the current deviation in meters, or null if no active route.
  /// The return value is forwarded to GuidanceController so deviation
  /// distance is only calculated once per GPS tick.
  double? onLocationUpdate(ll.LatLng position, {double? userHeadingDegrees}) {
    if (_currentRoute == null) return null;
    if (_status != RoutingStatus.active) return null;

    final deviation = _distanceToRoute(position);
    _lastDeviation = deviation;

    // Cache route bearing at nearest segment — used both here for the
    // dynamic threshold and by the screen for alignment-aware warnings.
    _lastRouteBearing = _routeBearingAtNearest(position);

    final effectiveThreshold = _effectiveThreshold(userHeadingDegrees);

    debugPrint(
      'Deviation: ${deviation.toStringAsFixed(1)}m '
      '(threshold ${effectiveThreshold.toStringAsFixed(0)}m, '
      'heading ${userHeadingDegrees?.toStringAsFixed(0) ?? "?"}°, '
      'route ${_lastRouteBearing?.toStringAsFixed(0) ?? "?"}°)',
    );

    final isDeviated = deviation > effectiveThreshold;

    if (isDeviated) {
      _deviationTickCount++;
      debugPrint(
        'Off route tick $_deviationTickCount/$_deviationTickThreshold',
      );
      if (_deviationTickCount >= _deviationTickThreshold) {
        _triggerReroute(position);
      }
    } else {
      // User is on route (or close enough given their heading) — reset
      // the debounce counter.
      _deviationTickCount = 0;
    }

    return deviation;
  }

  // ── Dynamic threshold ─────────────────────────────────────

  /// Computes the effective reroute threshold based on how well the user's
  /// heading aligns with the route at the nearest segment.
  ///
  /// The idea: if the user is walking the right way, be generous about
  /// lateral drift (parallel sidewalks, shortcuts across a plaza). If they
  /// are heading away from the route direction, react quickly because they
  /// almost certainly need a new route.
  ///
  /// Tiers:
  ///   aligned (< 45°  difference) → 45m  — parallel or nearly so
  ///   oblique (45–90° difference) → base threshold (default 20m)
  ///   opposed (> 90°  difference) → 15m  — user is walking away
  ///
  /// When no heading info is available, falls back to the base threshold.
  double _effectiveThreshold(double? userHeadingDegrees) {
    if (userHeadingDegrees == null) return deviationThresholdMeters;
    if (_lastRouteBearing == null) return deviationThresholdMeters;

    final angularDiff = _headingDifference(
      userHeadingDegrees,
      _lastRouteBearing!,
    );

    if (angularDiff < 45) return 45.0;
    if (angularDiff < 90) return deviationThresholdMeters;
    return 15.0;
  }

  // ── Rerouting ─────────────────────────────────────────────

  /// Fetch a new route from [currentPosition] to the stored destination.
  /// If the reroute request fails, status falls back to [RoutingStatus.active]
  /// so the user keeps navigating on the previous route rather than erroring out.
  Future<void> _triggerReroute(ll.LatLng currentPosition) async {
    if (_destination == null) return;

    // Guard: if a reroute is already in flight, don't stack another request.
    if (_status == RoutingStatus.rerouting) return;

    debugPrint('Rerouting from $currentPosition to $_destination');
    _setStatus(RoutingStatus.rerouting);

    final route = await getValhallaRoute(
      valhallaBaseUrl: _valhallaBaseUrl,
      origin: currentPosition,
      destination: _destination!,
      costing: costing,
    );

    if (route == null) {
      // Silent recovery — stay navigating on the old route, keep trying on
      // subsequent GPS ticks once the user is still off-route.
      debugPrint('Reroute failed, staying on previous route');
      _setStatus(RoutingStatus.active);
      return;
    }

    _applyRoute(route);
  }

  // ── Internals ─────────────────────────────────────────────

  /// Apply a fetched route as the new active route and reset deviation state.
  /// Called for both initial fetches and reroutes so both follow the same path.
  void _applyRoute(ValhallaRoute route) {
    _currentRoute = route;
    _deviationTickCount = 0;
    _lastRouteBearing = null;
    _setStatus(RoutingStatus.active);
  }

  void _setStatus(RoutingStatus status, {String? error}) {
    _status = status;
    _errorMessage = error;
    notifyListeners();
  }

  // ── Geometry helpers ──────────────────────────────────────

  /// Minimum perpendicular distance from [point] to any segment in the
  /// route polyline. More accurate than nearest-vertex distance because
  /// it accounts for where the user is *between* two polyline points.
  double _distanceToRoute(ll.LatLng point) {
    final polyline = _currentRoute!.polyline;
    if (polyline.length < 2) return 0;

    double minDist = double.infinity;
    for (int i = 0; i < polyline.length - 1; i++) {
      final d = _pointToSegmentDistance(point, polyline[i], polyline[i + 1]);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  /// Bearing of the route segment closest to [position]. Used for computing
  /// heading alignment so the reroute threshold can adapt.
  double? _routeBearingAtNearest(ll.LatLng position) {
    final polyline = _currentRoute!.polyline;
    if (polyline.length < 2) return null;

    double minDist = double.infinity;
    int nearestIndex = 0;

    for (int i = 0; i < polyline.length - 1; i++) {
      final d = _pointToSegmentDistance(position, polyline[i], polyline[i + 1]);
      if (d < minDist) {
        minDist = d;
        nearestIndex = i;
      }
    }

    return _bearingBetween(polyline[nearestIndex], polyline[nearestIndex + 1]);
  }

  /// Projects [p] onto segment [a]→[b] and returns the haversine distance
  /// from [p] to that closest point. t is clamped to [0,1] so the projection
  /// never escapes the endpoints of the segment.
  double _pointToSegmentDistance(ll.LatLng p, ll.LatLng a, ll.LatLng b) {
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude, py = p.latitude;

    final dx = bx - ax, dy = by - ay;
    final lenSq = dx * dx + dy * dy;

    double t = 0;
    if (lenSq != 0) {
      t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
      t = t.clamp(0.0, 1.0);
    }

    final closestLat = ay + t * dy;
    final closestLng = ax + t * dx;

    return _haversineMeters(p, ll.LatLng(closestLat, closestLng));
  }

  /// Haversine formula — returns the great-circle distance in meters
  /// between two lat/lng points. Used instead of the latlong2 Distance
  /// class so we can compute distance to an arbitrary projected point
  /// that may not be a real GPS coordinate.
  double _haversineMeters(ll.LatLng a, ll.LatLng b) {
    const R = 6371000.0;
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLng = _deg2rad(b.longitude - a.longitude);
    final sinDLat = sin(dLat / 2);
    final sinDLng = sin(dLng / 2);
    final h =
        sinDLat * sinDLat +
        cos(_deg2rad(a.latitude)) *
            cos(_deg2rad(b.latitude)) *
            sinDLng *
            sinDLng;
    return 2 * R * asin(sqrt(h));
  }

  /// Initial bearing from [a] to [b] in degrees, normalised to [0, 360).
  double _bearingBetween(ll.LatLng a, ll.LatLng b) {
    final lat1 = _deg2rad(a.latitude);
    final lat2 = _deg2rad(b.latitude);
    final dLng = _deg2rad(b.longitude - a.longitude);
    final y = sin(dLng) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  /// Absolute angular difference between two headings, in [0, 180].
  double _headingDifference(double h1, double h2) {
    final diff = (h1 - h2).abs() % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  double _deg2rad(double deg) => deg * pi / 180;
}
