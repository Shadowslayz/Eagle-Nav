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
import '../widgets/scan_overlay.dart';

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
  final ValueNotifier<ll.LatLng?> _destinationNotifier = ValueNotifier(null);
  bool _isPreviewFetch = false;
  bool _scanActive = false;
  bool _scanTipShown = false;

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

    // Defer heavy init so the first frame renders immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initialize();
    });
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

  void _onLocationUpdate() {
    final position = _locationController.currentLocation;
    if (position == null) return;

    final deviation = _routingController.onLocationUpdate(position);
    _guidanceController.onLocationUpdate(position, deviationMeters: deviation);

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
        upcomingTurnDirection: nextStep?.getTurnDirection(),
        upcomingStreetName: nextStep?.streetName,
      );
    }

    if (deviation != null && _guidanceController.isNavigating) {
      _navVoice.onDeviationUpdate(deviation);
    }

    if (_guidanceController.isNavigating && mounted) {
      _mapController.move(position, _mapController.camera.zoom);
    }
  }

  void _onRoutingUpdate() {
    if (_routingController.status == RoutingStatus.fetching) return;
    if (_routingController.status == RoutingStatus.rerouting) return;

    if (_routingController.status == RoutingStatus.active &&
        _routingController.currentRoute != null) {
      if (!_isPreviewFetch) {
        final route = _routingController.currentRoute!;
        _guidanceController.startNavigation(route);

        _guidanceController.onStepAdvanced = () {
          final step = _guidanceController.currentStep;
          final nextStep = _guidanceController.nextStep;
          final position = _locationController.currentLocation;
          if (step == null || position == null) return;

          _navVoice.announceStep(
            valhallaInstruction: step.instruction,
            maneuverType: step.maneuverType,
            distanceMeters: step.distanceMeters,
            stepEndLocation: step.endLocation,
            currentPosition: position,
            routePolyline: route.polyline,
            streetName: step.streetName ?? '',
            nextStreetName: nextStep?.streetName,
            nextTurnDirection: nextStep?.getTurnDirection(),
            nextTurnStreetName: nextStep?.streetName,
          );
        };

        _guidanceController.onArrival = () async {
          await Future.delayed(const Duration(seconds: 4));
          if (!mounted) return;
          _stopNavigation(isArrival: true);
          _uiController.setState(NavigationUIState.idle);
        };

        if (route.steps.isNotEmpty) {
          final step = route.steps.first;
          final nextStep = route.steps.length > 1 ? route.steps[1] : null;
          final position = _locationController.currentLocation;

          if (position != null) {
            _navVoice.announceStep(
              valhallaInstruction: step.instruction,
              maneuverType: step.maneuverType,
              distanceMeters: step.distanceMeters,
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

    if (_routingController.status == RoutingStatus.error) {
      _showSnackBar(_routingController.errorMessage ?? 'Routing error');
    }
  }

  // ── User actions ──────────────────────────────────────────

  void _onBuildingSelected(destination) {
    final entrance = destination.mainEntrance;
    if (entrance == null) return;

    final dest = ll.LatLng(entrance.latitude, entrance.longitude);
    _destination = dest;
    _destinationNotifier.value = dest;
    _mapController.move(dest, 17.0);

    _uiController.setState(
      NavigationUIState.destinationSelected,
      destination: destination,
    );
    _fetchPreviewRoute();

    // One-time scan tip
    if (!_scanTipShown) {
      _scanTipShown = true;
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.radar, color: Color(0xFFC9A227), size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Tap Scan when entering a building to detect obstacles.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF1A1A1A),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      });
    }
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
              isNavigating: _guidanceController.isNavigating,
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
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
    _destinationNotifier.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: GestureDetector(
        onDoubleTap: () => _navVoice.announceCurrentHeading(),
        child: Stack(
          children: [
            // ── Map — position updated imperatively via mapController ──
            FlutterMap(
              mapController: _mapController,
              options: const MapOptions(
                initialCenter: ll.LatLng(34.067, -118.170),
                initialZoom: 16.0,
                interactionOptions: InteractionOptions(
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

                // Polyline: only rebuilds when route or navigation state changes
                ListenableBuilder(
                  listenable: Listenable.merge([
                    _routingController,
                    _guidanceController,
                  ]),
                  builder: (context, _) {
                    final polyline =
                        _routingController.currentRoute?.polyline ?? [];
                    if (polyline.isEmpty) return const SizedBox.shrink();
                    final isNavigating = _guidanceController.isNavigating;
                    final isRerouting = _routingController.isRerouting;
                    return PolylineLayer(
                      simplificationTolerance: 0.0,
                      polylines: [
                        Polyline(
                          points: polyline,
                          strokeWidth: 40.0,
                          color: Colors.blue.withOpacity(0.12),
                          borderStrokeWidth: 1.5,
                          borderColor: Colors.blue.withOpacity(0.25),
                          strokeCap: StrokeCap.round,
                          strokeJoin: StrokeJoin.round,
                        ),
                        Polyline(
                          points: polyline,
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
                    );
                  },
                ),

                // Markers: only rebuilds when location or destination changes
                ListenableBuilder(
                  listenable: Listenable.merge([
                    _locationController,
                    _destinationNotifier,
                    _uiController,
                  ]),
                  builder: (context, _) {
                    final position = _locationController.currentLocation;
                    final destination = _destinationNotifier.value;
                    return MarkerLayer(
                      markers: [
                        if (position != null)
                          Marker(
                            point: position,
                            width: 60,
                            height: 60,
                            child: ValueListenableBuilder<double>(
                              valueListenable:
                                  _navVoice.compassHeadingNotifier,
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
                        if (destination != null)
                          Marker(
                            point: destination,
                            width: 140,
                            height: 68,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1A1A1A),
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black38,
                                        blurRadius: 6,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    _uiController.selectedDestination?.name ??
                                        'Destination',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(
                                  Icons.location_pin,
                                  color: Color(0xFFC9A227),
                                  size: 30,
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),

            // ── Navigation overlays — only rebuild on state changes ──
            ListenableBuilder(
              listenable: Listenable.merge([
                _guidanceController,
                _uiController,
              ]),
              builder: (context, _) {
                final isNavigating = _guidanceController.isNavigating;
                final isDestinationSelected =
                    _uiController.state ==
                    NavigationUIState.destinationSelected;
                final currentStep = _guidanceController.currentStep;

                return Stack(
                  children: [
                    // ── Search bar ────────────────────────────
                    if (!isNavigating)
                      Positioned(
                        top: topPadding + 16,
                        left: 16,
                        right: 16,
                        child: BuildingSearchBar(
                          onBuildingSelected: _onBuildingSelected,
                        ),
                      ),

                    // ── Recenter button ───────────────────────
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      right: 16,
                      bottom:
                          (isNavigating || isDestinationSelected) ? 240 : 100,
                      child: FloatingActionButton(
                        heroTag: 'recenter_btn_safe',
                        backgroundColor: const Color(0xFF1A1A1A),
                        elevation: 4,
                        onPressed: () {
                          final userLocation =
                              _locationController.currentLocation;
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
                        child: const Icon(
                          Icons.my_location,
                          color: Color(0xFFC9A227),
                        ),
                      ),
                    ),

                    // ── Zoom buttons ──────────────────────────
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      left: 16,
                      bottom:
                          (isNavigating || isDestinationSelected) ? 240 : 100,
                      child: Column(
                        children: [
                          FloatingActionButton(
                            heroTag: 'zoom_in',
                            mini: true,
                            backgroundColor: const Color(0xFF1A1A1A),
                            elevation: 4,
                            onPressed: _zoomIn,
                            child: const Icon(Icons.add, color: Colors.white),
                          ),
                          const SizedBox(height: 10),
                          FloatingActionButton(
                            heroTag: 'zoom_out',
                            mini: true,
                            backgroundColor: const Color(0xFF1A1A1A),
                            elevation: 4,
                            onPressed: _zoomOut,
                            child: const Icon(Icons.remove, color: Colors.white),
                          ),
                        ],
                      ),
                    ),

                    // ── Scan FAB ──────────────────────────────
                    Positioned(
                      bottom: (isNavigating || isDestinationSelected) ? 240 : 100,
                      right: 80,
                      child: Semantics(
                        label: 'Obstacle scan',
                        button: true,
                        child: FloatingActionButton.extended(
                          heroTag: 'scan_btn',
                          backgroundColor: const Color(0xFF1A1A1A),
                          elevation: 4,
                          icon: const Icon(Icons.radar, color: Color(0xFFC9A227)),
                          label: const Text(
                            'Scan',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          onPressed: () => setState(() => _scanActive = true),
                        ),
                      ),
                    ),

                    // ── Turn-by-turn panel ────────────────────
                    if (currentStep != null && isNavigating)
                      Positioned(
                        top: 76,
                        left: 16,
                        right: 16,
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            _navVoice,
                            _routingController,
                          ]),
                          builder: (context, _) => _TurnByTurnPanel(
                            instruction: _navVoice.lastDisplayText.isNotEmpty
                                ? _navVoice.lastDisplayText
                                : currentStep.instruction,
                            distanceMeters: currentStep.distanceMeters,
                            isRerouting: _routingController.isRerouting,
                          ),
                        ),
                      ),

                    // ── Rerouting banner ──────────────────────
                    if (_routingController.isRerouting)
                      const Positioned(
                        top: 76,
                        left: 16,
                        right: 16,
                        child: _ReroutingBanner(),
                      ),
                  ],
                );
              },
            ),

            // ── Bottom panel ──────────────────────────────────
            _buildBottomPanel(),

            // ── Scan overlay ───────────────────────────────────
            if (_scanActive)
              Positioned.fill(
                child: ScanOverlay(
                  onDismiss: () => setState(() => _scanActive = false),
                ),
              ),
          ],
        ),
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

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFC9A227).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.navigation, color: Color(0xFFC9A227), size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    instruction,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      height: 1.3,
                    ),
                  ),
                  if (distanceMeters != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'in ${_formatDistance(distanceMeters!)}',
                      style: const TextStyle(
                        color: Color(0xFFC9A227),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orange.shade800,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          SizedBox(width: 12),
          Text(
            'Recalculating route…',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
