import 'package:eaglenav/features/navigation/controllers/location_controller.dart';
import 'package:eaglenav/features/navigation/controllers/ui_navigation_controller.dart';
import 'package:eaglenav/features/navigation/routing/controllers/routing_controller.dart';
import 'package:eaglenav/features/navigation/controllers/guidance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../controllers/navigation_voice_controller.dart';
import '/config/app_config.dart';
import '../services/location_service.dart';
import '../widgets/building_search_bar.dart';
import '../widgets/pulsing_location_marker.dart';
import '../widgets/destination_selection_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  NAVIGATION SCREEN
// ─────────────────────────────────────────────────────────────────────────────
//
//  The only class that holds references to all the controllers. It acts as
//  a router: GPS ticks flow in through LocationController, fan out to
//  RoutingController (deviation + reroute), GuidanceController (step
//  progression), and NavigationVoiceController (speech). Controllers never
//  reference each other directly — all coordination happens here.
//
// ─────────────────────────────────────────────────────────────────────────────

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  late final MapController _mapController;
  late final LocationController _locationController;
  late final RoutingController _routingController;
  late final GuidanceController _guidanceController;
  late final NavigationVoiceController _navVoice;
  late final UiNavigationController _uiController;

  ll.LatLng? _destination;
  bool _isPreviewFetch = false;
  double totalTimeSeconds = 0;

  @override
  void initState() {
    super.initState();

    _mapController = MapController();
    _locationController = LocationController(LocationService());
    _routingController = RoutingController(
      valhallaBaseUrl: AppConfig.valhallaBaseUrl,
    );
    _guidanceController = GuidanceController();
    _navVoice = NavigationVoiceController();
    _navVoice.initialize();
    _uiController = UiNavigationController();

    _locationController.addListener(_onLocationUpdate);
    _routingController.addListener(_onRoutingUpdate);

    _initialize();
  }

  Future<void> _initialize() async {
    await _locationController.initialize();
    if (!mounted) return;

    switch (_locationController.status) {
      case LocationStatus.active:
        _mapController.move(_locationController.currentLocation!, 16.0);
        break;
      case LocationStatus.serviceDisabled:
      case LocationStatus.permissionDenied:
      case LocationStatus.permissionDeniedForever:
      case LocationStatus.error:
        _showSnackBar(_locationController.errorMessage ?? 'Location error');
        break;
      default:
        break;
    }
  }

  // ── Controller listeners ──────────────────────────────────

  /// Fires whenever LocationController emits a new GPS position.
  /// Fans the tick out to each controller. Reads the compass heading once
  /// so both Routing (dynamic reroute threshold) and Voice (off-course
  /// suppression) use the same signal.
  void _onLocationUpdate() {
    final position = _locationController.currentLocation;
    if (position == null) return;

    // Shared signal — used twice below.
    final userHeading = _navVoice.currentHeading;

    // RoutingController computes deviation AND uses the heading to pick
    // an effective threshold. It also caches the route bearing at the
    // nearest segment, which we read below for the off-course suppression.
    final deviation = _routingController.onLocationUpdate(
      position,
      userHeadingDegrees: userHeading,
    );
    _guidanceController.onLocationUpdate(position, deviationMeters: deviation);

    // Phase 1 monitor — transitions to Phase 2 once the user reaches the
    // walkable network. No-op during normal navigation.
    _navVoice.onApproachUpdate(position);

    // Distance countdown alerts — "in 8 steps, turn right" etc.
    final step = _guidanceController.currentStep;
    final nextStep = _guidanceController.nextStep;

    if (step != null) {
      const dist = ll.Distance();
      final remaining = dist.as(
        ll.LengthUnit.Meter,
        position,
        step.endLocation,
      );
      _navVoice.onDistanceUpdate(
        remaining,
        upcomingTurnDirection: nextStep?.getTurnDirection(), // keep this
        upcomingStreetName: nextStep?.streetName,
      );
    }

    // Off-course warning — suppressed when the user is aligned with the
    // route direction, since they're probably on a parallel sidewalk and
    // don't need to hear about it.
    if (deviation != null && _guidanceController.isNavigating) {
      final routeBearing = _routingController.lastRouteBearingAtUser;
      final isAligned = routeBearing != null
          ? _headingDifference(userHeading, routeBearing) < 45
          : false;

      _navVoice.onDeviationUpdate(deviation, userIsAligned: isAligned);
    }

    // Keep the map centred on the user during active navigation.
    if (_guidanceController.isNavigating && mounted) {
      _mapController.move(position, _mapController.camera.zoom);
    }
  }

  /// Absolute angular difference between two headings, in [0, 180].
  /// Mirrors RoutingController's own helper so we stay consistent without
  /// creating a cross-controller dependency.
  double _headingDifference(double h1, double h2) {
    final diff = (h1 - h2).abs() % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  /// Fires whenever RoutingController changes state (fetched, active,
  /// rerouting, error). Wires the guidance callbacks, kicks off the first
  /// step announcement (with Phase 1 fallback), and handles error UI.
  void _onRoutingUpdate() {
    if (_routingController.status == RoutingStatus.fetching) return;

    // Silence corrections while a reroute is in flight — the user will
    // hear "Rerouting." from the voice controller and we don't want
    // off-course warnings overlapping with that.
    if (_routingController.status == RoutingStatus.rerouting) {
      _navVoice.onRerouting();
      return;
    }

    if (_routingController.status == RoutingStatus.active &&
        _routingController.currentRoute != null) {
      final route = _routingController.currentRoute!;

      setState(() {
        totalTimeSeconds = route.totalTimeSeconds;
      });

      if (!_isPreviewFetch) {
        _guidanceController.startNavigation(route);

        // ── Imminent turn cue ─────────────────────────────────
        // Fires the moment the user crosses into a step whose maneuver
        // is a turn. Reads the NEW current step (already advanced by the
        // controller) so the cue matches the turn happening right now.
        // Runs BEFORE onStepAdvanced so the short "turn now" phrase hits
        // the TTS queue first, then the longer announceStep follows with
        // full context (street name, distance).
        _guidanceController.onTurnImminent = () {
          final step = _guidanceController.currentStep;
          if (step == null) return;

          final turn = step.getTurnDirection();
          if (turn == null) return;

          _navVoice.announceTurnNow(
            maneuverType: step.maneuverType,
            turnDirection: turn,
          );
        };

        // ── Subsequent steps — user is already on network ─────
        // No off-network check needed here — by definition the user
        // is walking and has already passed the first path entry point.
        _guidanceController.onStepAdvanced = () {
          final step = _guidanceController.currentStep;
          final nextStep = _guidanceController.nextStep;
          final position = _locationController.currentLocation;
          if (step == null || position == null) return;

          const dist = ll.Distance();
          final remaining = dist.as(
            ll.LengthUnit.Meter,
            position,
            step.endLocation,
          );

          _navVoice.announceStep(
            valhallaInstruction: step.instruction,
            maneuverType: step.maneuverType,
            distanceMeters: remaining,
            stepEndLocation: step.endLocation,
            currentPosition: position,
            routePolyline: route.polyline,
            streetName: step.streetName ?? '',
            nextStreetName: nextStep?.streetName,
            nextTurnDirection: nextStep?.getTurnDirection(),
            nextTurnStreetName: nextStep?.streetName,
          );
        };

        // ── Arrival ───────────────────────────────────────────
        _guidanceController.onArrival = () async {
          await Future.delayed(const Duration(seconds: 4));
          if (!mounted) return;
          _stopNavigation(isArrival: true);
          _uiController.setState(NavigationUIState.idle);
        };

        // ── First step — two-phase check ──────────────────────
        // Phase 1: user is off the walkable network (e.g. in cafeteria, on grass)
        //          → orient them toward the path entry point
        // Phase 2: user is already on the path
        //          → start normal Valhalla guidance immediately
        if (route.steps.isNotEmpty) {
          final step = route.steps.first;
          final nextStep = route.steps.length > 1 ? route.steps[1] : null;
          final position = _locationController.currentLocation;

          if (position != null) {
            const dist = ll.Distance();

            final remaining = dist.as(
              ll.LengthUnit.Meter,
              position,
              step.endLocation,
            );

            final distanceToPath = dist.as(
              ll.LengthUnit.Meter,
              position,
              route.polyline.first,
            );

            if (distanceToPath > 15.0) {
              // ── Phase 1 — off network ────────────────────────
              _navVoice.announceApproachToPath(
                currentPosition: position,
                pathEntryPoint: route.polyline.first,
                streetName: step.streetName ?? '',
                onReached: () {
                  // ── Phase 2 — on network, start real guidance
                  _navVoice.announceStep(
                    valhallaInstruction: step.instruction,
                    maneuverType: step.maneuverType,
                    distanceMeters: remaining,
                    stepEndLocation: step.endLocation,
                    currentPosition: position,
                    routePolyline: route.polyline,
                    streetName: step.streetName ?? '',
                    nextStreetName: nextStep?.streetName,
                    nextTurnDirection: nextStep?.getTurnDirection(),
                    nextTurnStreetName: nextStep?.streetName,
                  );
                },
              );
            } else {
              // ── Already on path — skip Phase 1 ───────────────
              _navVoice.announceStep(
                valhallaInstruction: step.instruction,
                maneuverType: step.maneuverType,
                distanceMeters: remaining,
                stepEndLocation: step.endLocation,
                currentPosition: position,
                routePolyline: route.polyline,
                streetName: step.streetName ?? '',
                nextStreetName: nextStep?.streetName,
                nextTurnDirection: nextStep?.getTurnDirection(),
                nextTurnStreetName: nextStep?.streetName,
              );
            }
          }
        }
      }
    }

    if (_routingController.status == RoutingStatus.error) {
      _showSnackBar(_routingController.errorMessage ?? 'Routing error');
    }
  }

  // ── User actions ──────────────────────────────────────────

  void _onBuildingSelected(destination) {
    final position = _locationController.currentLocation;

    // Use nearest entrance if we have a GPS fix, otherwise fall back to main
    final entrance = position != null
        ? destination.nearestEntrance(position.latitude, position.longitude)
        : destination.mainEntrance;

    if (entrance == null) return;

    final dest = ll.LatLng(entrance.latitude, entrance.longitude);
    setState(() => _destination = dest);
    _mapController.move(dest, 17.0);

    _uiController.setState(
      NavigationUIState.destinationSelected,
      destination: destination,
    );
    _fetchPreviewRoute();
  }

  Future<void> _fetchPreviewRoute() async {
    final origin = _locationController.currentLocation;
    if (origin == null || _destination == null) return;

    _isPreviewFetch = true;
    await _routingController.fetchRoute(origin, _destination!);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final points = _routingController.currentRoute?.polyline ?? [];
      if (points.length < 2) return;
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(80),
          maxZoom: 17,
        ),
      );
    });
  }

  Future<void> _loadRoute() async {
    if (_destination == null) {
      _showSnackBar('Select a destination first');
      return;
    }
    final origin = _locationController.currentLocation;
    if (origin == null) {
      _showSnackBar('Waiting for GPS...');
      return;
    }

    await _routingController.fetchRoute(origin, _destination!);
    if (!mounted) return;

    if (_routingController.status == RoutingStatus.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final points = _routingController.currentRoute?.polyline ?? [];
        if (points.length < 2) return;
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(100),
            maxZoom: 15,
          ),
        );
      });
      _showSnackBar('Route loaded!');
    }
  }

  Future<void> _startNavigation() async {
    _isPreviewFetch = false;
    if (_destination == null) {
      _showSnackBar('Select a destination first');
      return;
    }
    if (_guidanceController.isNavigating) {
      _stopNavigation();
      _uiController.setState(NavigationUIState.idle);
      return;
    }
    final origin = _locationController.currentLocation;
    if (origin == null) {
      _showSnackBar('Waiting for GPS...');
      return;
    }

    await _routingController.fetchRoute(origin, _destination!);
  }

  void _stopNavigation({bool isArrival = false}) {
    _guidanceController.stopNavigation();
    _routingController.clearRoute();

    // Only stop audio if manually cancelled.
    // On arrival let TTS finish speaking.
    if (!isArrival) {
      _navVoice.stop();
    }
  }

  // ── Helpers ───────────────────────────────────────────────

  Widget _buildBottomPanel() {
    return ListenableBuilder(
      listenable: Listenable.merge([_uiController, _guidanceController]),
      builder: (context, _) {
        if (_uiController.state == NavigationUIState.destinationSelected ||
            _guidanceController.isNavigating) {
          final dest = _uiController.selectedDestination;

          return Positioned(
            bottom: 20,
            left: 16,
            right: 16,
            child: DestinationSelectionSheet(
              onCancel: () {
                _stopNavigation();
                _uiController.setState(NavigationUIState.idle);
              },
              onStart: _startNavigation,
              onLoad: _loadRoute,
              destinationName: dest?.name ?? 'Destination',
              walkingTime: getFormattedTime(totalTimeSeconds),
              isNavigating: _guidanceController.isNavigating,
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  int getFormattedTime(double totalSeconds) {
    return (totalSeconds / 60).ceil();
  }

  void _zoomIn() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom + 1);
  }

  void _zoomOut() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom - 1);
  }

  void _showSnackBar(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  @override
  void dispose() {
    _locationController.removeListener(_onLocationUpdate);
    _routingController.removeListener(_onRoutingUpdate);
    _locationController.dispose();
    _routingController.dispose();
    _guidanceController.dispose();
    _navVoice.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([
          _locationController,
          _routingController,
          _guidanceController,
          _navVoice,
        ]),
        builder: (context, _) {
          final position = _locationController.currentLocation;
          final polyline = _routingController.currentRoute?.polyline ?? [];
          final isNavigating = _guidanceController.isNavigating;
          final currentStep = _guidanceController.currentStep;
          final isRerouting = _routingController.isRerouting;
          final isDestinationSelected =
              _uiController.state == NavigationUIState.destinationSelected;

          return GestureDetector(
            onDoubleTap: () => _navVoice.announceCurrentHeading(
              currentPosition: _locationController.currentLocation,
              currentStreetName: _guidanceController.currentStep?.streetName,
              isOnRoute: (_routingController.lastDeviation ?? 0) < 20,
            ),
            child: Stack(
              children: [
                // ── Map ──────────────────────────────────────
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter:
                        position ?? const ll.LatLng(34.067, -118.170),
                    initialZoom: 16.0,
                    interactionOptions: const InteractionOptions(
                      flags:
                          InteractiveFlag.drag |
                          InteractiveFlag.pinchZoom |
                          InteractiveFlag.rotate,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.eagle_nav_app',
                      maxZoom: 19.0,
                      minZoom: 12.0,
                    ),
                    PolylineLayer(
                      simplificationTolerance: 0.0,
                      polylines: [
                        if (polyline.isNotEmpty)
                          Polyline(
                            points: [...polyline],
                            strokeWidth: 40.0,
                            color: Colors.blue.withOpacity(0.12),
                            borderStrokeWidth: 1.5,
                            borderColor: Colors.blue.withOpacity(0.25),
                            strokeCap: StrokeCap.round,
                            strokeJoin: StrokeJoin.round,
                          ),
                        if (polyline.isNotEmpty)
                          Polyline(
                            points: [...polyline],
                            strokeWidth: 4,
                            color: isNavigating
                                ? Colors.blue
                                : isRerouting
                                ? Colors.orange
                                : Colors.grey,
                            strokeCap: StrokeCap.round,
                            strokeJoin: StrokeJoin.round,
                          ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        if (position != null)
                          Marker(
                            point: position,
                            width: 60,
                            height: 60,
                            child: ValueListenableBuilder<double>(
                              valueListenable: _navVoice.compassHeadingNotifier,
                              builder: (context, heading, _) {
                                return PulsingLocationMarker(
                                  size: 20.0,
                                  dotColor: Colors.blue,
                                  pulseColor: Colors.blue,
                                  heading: heading,
                                );
                              },
                            ),
                          ),
                        if (_destination != null)
                          Marker(
                            point: _destination!,
                            width: 120,
                            height: 60,
                            child: Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    _uiController.selectedDestination?.name ??
                                        'Destination',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(
                                  Icons.location_pin,
                                  color: Colors.red,
                                  size: 28,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),

                // ── Search bar ────────────────────────────────
                if (!isNavigating)
                  Positioned(
                    top: topPadding + 16,
                    left: 16,
                    right: 16,
                    child: BuildingSearchBar(
                      onBuildingSelected: _onBuildingSelected,
                    ),
                  ),

                // ── Recenter button ───────────────────────────
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  right: 16,
                  bottom: (isNavigating || isDestinationSelected) ? 240 : 120,
                  child: FloatingActionButton(
                    heroTag: 'recenter_btn_safe',
                    backgroundColor: Colors.white,
                    onPressed: () {
                      final userLocation = _locationController.currentLocation;
                      if (userLocation != null) {
                        _mapController.move(
                          userLocation,
                          _mapController.camera.zoom,
                        );
                        _mapController.rotate(
                          _navVoice.compassHeadingNotifier.value,
                        );
                      }
                    },
                    child: const Icon(Icons.my_location, color: Colors.blue),
                  ),
                ),

                // ── Zoom buttons ──────────────────────────────
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  left: 16,
                  bottom: (isNavigating || isDestinationSelected) ? 240 : 120,
                  child: Column(
                    children: [
                      FloatingActionButton(
                        heroTag: 'zoom_in',
                        mini: true,
                        backgroundColor: Colors.white,
                        onPressed: _zoomIn,
                        child: const Icon(Icons.add, color: Colors.black),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton(
                        heroTag: 'zoom_out',
                        mini: true,
                        backgroundColor: Colors.white,
                        onPressed: _zoomOut,
                        child: const Icon(Icons.remove, color: Colors.black),
                      ),
                    ],
                  ),
                ),

                // ── Bottom panel ──────────────────────────────
                _buildBottomPanel(),

                // ── Turn-by-turn panel ────────────────────────
                if (currentStep != null && isNavigating)
                  Positioned(
                    top: 76,
                    left: 16,
                    right: 16,
                    child: _TurnByTurnPanel(
                      instruction: _navVoice.lastDisplayText.isNotEmpty
                          ? _navVoice.lastDisplayText
                          : currentStep.instruction,
                      distanceMeters: currentStep.distanceMeters,
                      isRerouting: isRerouting,
                    ),
                  ),

                // ── Rerouting banner ──────────────────────────
                if (isRerouting)
                  const Positioned(
                    top: 76,
                    left: 16,
                    right: 16,
                    child: _ReroutingBanner(),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _TurnByTurnPanel extends StatelessWidget {
  final String instruction;
  final double? distanceMeters;
  final bool isRerouting;

  const _TurnByTurnPanel({
    required this.instruction,
    this.distanceMeters,
    this.isRerouting = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blue.shade700,
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.navigation, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    instruction,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (distanceMeters != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'in ${distanceMeters!.toStringAsFixed(0)} m',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReroutingBanner extends StatelessWidget {
  const _ReroutingBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.orange.shade700,
      elevation: 8,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 12),
            Text(
              'Recalculating route...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
