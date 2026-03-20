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
///   - Trigger a reroute when deviation exceeds threshold for long enough
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
  /// How far off-route (in meters) before a reroute is considered
  final double deviationThresholdMeters;

  /// How long the user must stay off-route before reroute triggers.
  /// Prevents false positives from GPS noise or brief detours.
  final Duration deviationDebounce;

  /// Valhalla costing model — e.g. 'pedestrian', 'auto', 'bicycle'
  final String costing;

  // ── State ─────────────────────────────────────────────────
  ValhallaRoute? _currentRoute;
  RoutingStatus _status = RoutingStatus.idle;
  String? _errorMessage;
  ll.LatLng? _destination;

  // ── Deviation tracking ────────────────────────────────────
  /// Timestamp of when the user first went off-route in the current deviation
  /// window. Reset when user returns to route or a new route is applied.
  DateTime? _deviationStartTime;

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
    // _deviationStartTime = null;
    _setStatus(RoutingStatus.idle);
  }

  // ── Location updates ──────────────────────────────────────

  /// Called on every GPS tick from LocationController (via the navigation screen
  /// or a coordinator). Measures how far the user is from the route and triggers
  /// a reroute if they've been off-route longer than [deviationDebounce].
  ///
  /// Returns the current deviation in meters, or null if no active route.
  /// The return value is forwarded to GuidanceController so deviation distance
  /// is only calculated once per GPS tick.
  double? onLocationUpdate(ll.LatLng position) {
    if (_currentRoute == null) return null;
    if (_status != RoutingStatus.active) return null;

    final deviation = _distanceToRoute(position);
    debugPrint('Deviation: ${deviation.toStringAsFixed(1)}m');
    final isDeviated = deviation > deviationThresholdMeters;

    if (isDeviated) {
      // Start the debounce clock on first off-route tick
      //_deviationStartTime ??= DateTime.now();
      _deviationTickCount++;
      debugPrint(
        'Off route tick $_deviationTickCount/$_deviationTickThreshold',
      );
      //final elapsed = DateTime.now().difference(_deviationStartTime!);
      if (_deviationTickCount >= _deviationTickThreshold) {
        _triggerReroute(position);
      }
      //if (elapsed >= deviationDebounce) {
      // _triggerReroute(position);
      // }
    } else {
      // User is back on route — reset the deviation window
      //_deviationStartTime = null;
      _deviationTickCount = 0;
    }

    return deviation;
  }

  // ── Rerouting ─────────────────────────────────────────────

  /// Fetch a new route from [currentPosition] to the stored destination.
  /// If the reroute request fails, status falls back to [RoutingStatus.active]
  /// so the user keeps navigating on the previous route rather than erroring out.
  Future<void> _triggerReroute(ll.LatLng currentPosition) async {
    if (_destination == null) return;

    // Guard: if a reroute is already in flight, don't stack another request
    if (_status == RoutingStatus.rerouting) return;

    debugPrint('📍 Rerouting from $currentPosition to $_destination');
    _deviationStartTime = null; // clear before async gap
    _setStatus(RoutingStatus.rerouting);

    final route = await getValhallaRoute(
      valhallaBaseUrl: _valhallaBaseUrl,
      origin: currentPosition,
      destination: _destination!,
      costing: costing,
    );

    if (route == null) {
      // Silent recovery — stay navigating on the old route, keep trying on
      // subsequent GPS ticks once the user is still off-route
      debugPrint('Reroute failed, staying on previous route');
      _setStatus(RoutingStatus.active);
      return;
    }

    _applyRoute(route);
  }

  // ── Internals ─────────────────────────────────────────────

  /// Apply a fetched route as the new active route and reset deviation state.
  /// Called for both initial fetches and reroutes so both follow the same path.
  /// _deviationStartTime is reset here so a fresh route always starts the
  /// debounce clock clean.
  void _applyRoute(ValhallaRoute route) {
    _currentRoute = route;
    _deviationTickCount = 0;
    //_deviationStartTime = null;
    _setStatus(RoutingStatus.active);
  }

  void _setStatus(RoutingStatus status, {String? error}) {
    _status = status;
    _errorMessage = error;
    notifyListeners();
  }

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

  double _deg2rad(double deg) => deg * pi / 180;
}
