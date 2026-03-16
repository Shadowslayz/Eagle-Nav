import 'package:eaglenav/features/navigation/controllers/location_controller.dart';
import 'package:eaglenav/features/navigation/controllers/ui_navigation_controller.dart';
import 'package:eaglenav/features/navigation/routing/controllers/routing_controller.dart';
import 'package:eaglenav/features/navigation/controllers/guidance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import '/config/app_config.dart';
import '../services/location_service.dart';
import '../widgets/building_search_bar.dart';
import '../widgets/pulsing_location_marker.dart';
import '../widgets/destination_selection_sheet.dart';

/// ─── NavigationScreen ────────────────────────────────────────────────────────
///
/// The single presentation layer for the navigation feature.
/// Owns no business logic — it wires four controllers together and reacts
/// to their state.
///
/// Controller responsibilities:
///   LocationController  → permissions, GPS stream, currentLocation
///   RoutingController   → route fetching, polyline, deviation, rerouting
///   GuidanceController  → step progression, TTS announcements, haptics
///   UiNavigationController → UI state machine of navigation states
///
/// Wiring on each GPS tick:
///   1. LocationController notifies with new position
///   2. Screen pushes position into RoutingController.onLocationUpdate()
///      which returns the deviation distance (already computed)
///   3. Screen pushes position + deviation into GuidanceController.onLocationUpdate()
///
/// When RoutingController emits a new route (initial fetch or reroute):
///   Screen calls GuidanceController.startNavigation(newRoute) so guidance
///   always tracks the most current route geometry.
/// ─────────────────────────────────────────────────────────────────────────────

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  // Initialize the controllers
  late final MapController _mapController;
  late final LocationController _locationController;
  late final RoutingController _routingController;
  late final GuidanceController _guidanceController;
  late final UiNavigationController _uiController;

  ll.LatLng? _destination;

  @override
  void initState() {
    super.initState();

    _mapController = MapController();

    _locationController = LocationController(LocationService());
    _routingController = RoutingController(
      valhallaBaseUrl: AppConfig.valhallaBaseUrl,
    );
    _guidanceController = GuidanceController();
    _uiController = UiNavigationController();

    // ── Wire: location → routing + guidance ───────────────
    // On every GPS tick, push the position through both controllers.
    // RoutingController.onLocationUpdate returns deviation so we don't
    // calculate it twice.
    _locationController.addListener(_onLocationUpdate);

    // ── Wire: routing → guidance ──────────────────────────
    // When RoutingController gets a new route (initial or reroute),
    // restart guidance on it so GuidanceController always tracks
    // the current geometry.
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

  void _onLocationUpdate() {
    final position = _locationController.currentLocation;
    if (position == null) return;

    // Push into routing — get deviation back in one call
    final deviation = _routingController.onLocationUpdate(position);

    // Push into guidance — pass deviation so it's not recomputed
    _guidanceController.onLocationUpdate(position, deviationMeters: deviation);

    // Keep map centered during navigation
    if (_guidanceController.isNavigating && mounted) {
      _mapController.move(position, _mapController.camera.zoom);
    }
  }

  void _onRoutingUpdate() {
    // If routing just applied a new route (status flipped to active),
    // hand it to guidance so step tracking restarts on the new geometry.
    if (_routingController.status == RoutingStatus.active &&
        _routingController.currentRoute != null) {
      _guidanceController.startNavigation(_routingController.currentRoute!);
    }

    // Surface routing errors to the user
    if (_routingController.status == RoutingStatus.error) {
      _showSnackBar(_routingController.errorMessage ?? 'Routing error');
    }
  }

  // ── User actions ──────────────────────────────────────────

  // user selects building
  void _onBuildingSelected(destination) {
    final entrance = destination.mainEntrance;
    if (entrance == null) return;

    final dest = ll.LatLng(entrance.latitude, entrance.longitude);
    setState(() => _destination = dest);
    _mapController.move(dest, 17.0);

    _uiController.setState(
      NavigationUIState.destinationSelected,
      destination: destination,
    );
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
      // Fit map to route bounds
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
    if (_destination == null) {
      _showSnackBar('Select a destination first');
      return;
    }
    // Check if we are already navigating; if so, this button acts as "End"
    if (_guidanceController.isNavigating) {
      _stopNavigation();
      _uiController.setState(NavigationUIState.idle); // Close the sheet
      return;
    }
    final origin = _locationController.currentLocation;
    if (origin == null) {
      _showSnackBar('Waiting for GPS...');
      return;
    }

    // fetchRoute triggers _onRoutingUpdate which calls
    // GuidanceController.startNavigation — no extra wiring needed here
    await _routingController.fetchRoute(origin, _destination!);
  }

  void _stopNavigation() {
    _guidanceController.stopNavigation();
    _routingController.clearRoute();
  }

  // ── Helpers ───────────────────────────────────────────────
  Widget _buildBottomPanel() {
    return ListenableBuilder(
      //  listen to both controllers to ensure the button reacts to navigation status
      listenable: Listenable.merge([_uiController, _guidanceController]),
      builder: (context, _) {
        // if a destination is selected OR if we are actively navigating
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
              destinationName: dest?.name ?? "Destination",
              // flag to check
              isNavigating: _guidanceController.isNavigating,
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  /// Zoom in logic
  void _zoomIn() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom + 1);
  }

  /// Zoom out logic
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
    _mapController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Scaffold(
      body: ListenableBuilder(
        // Rebuild when any controller changes
        listenable: Listenable.merge([
          _locationController,
          _routingController,
          _guidanceController,
        ]),
        builder: (context, _) {
          final position = _locationController.currentLocation;
          final polyline = _routingController.currentRoute?.polyline ?? [];
          final isNavigating = _guidanceController.isNavigating;
          final currentStep = _guidanceController.currentStep;
          final isRerouting = _routingController.isRerouting;
          final isDestinationSelected = _uiController.state == NavigationUIState.destinationSelected;

          return Stack(
            children: [
              // ── Map ──────────────────────────────────────
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: position ?? const ll.LatLng(34.067, -118.170),
                  initialZoom: 16.0,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
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
                    polylines: [
                      if (polyline.isNotEmpty)
                        Polyline(
                          points: polyline,
                          strokeWidth: 4,
                          color: isNavigating
                              ? Colors.blue
                              : isRerouting
                              ? Colors.orange
                              : Colors.grey,
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
                          child: const PulsingLocationMarker(
                            size: 20.0,
                            dotColor: Colors.blue,
                            pulseColor: Colors.blue,
                          ),
                        ),
                      if (polyline.isNotEmpty)
                        Marker(
                          point: polyline.last,
                          width: 40,
                          height: 40,
                          child: const Icon(
                            Icons.flag,
                            color: Colors.red,
                            size: 40,
                          ),
                        ),
                    ],
                  ),
                ],
              ),

              // ── Search bar ────────────────────────────────
              Positioned(
                // Phone's safe area + 16 pixels of breathing room
                top: topPadding + 16,
                left: 16,
                right: 16,
                child: BuildingSearchBar(
                  onBuildingSelected: _onBuildingSelected,
                ),
              ),

              // Zoom buttons overlay
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                left: 16,
                // Move up if we are selecting a destination OR if we are already navigating
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

              // -- Navigation panel (UI state machine) ────────────────────────
              _buildBottomPanel(),

              // ── Turn-by-turn panel ────────────────────────
              if (currentStep != null && isNavigating)
                Positioned(
                  top: 76,
                  left: 16,
                  right: 16,
                  child: _TurnByTurnPanel(
                    instruction: currentStep.instruction,
                    distanceMeters:
                        _guidanceController.currentStep?.distanceMeters,
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

              // ── Debug overlay ─────────────────────────────
              // Positioned(
              //   bottom: 10,
              //   left: 10,
              //   child: _DebugOverlay(
              //     polylinePoints: polyline.length,
              //     position: position,
              //     status: _routingController.status,
              //     locationStatus: _locationController.status,
              //   ),
              // ),

              // ── FABs ──────────────────────────────────────
              Positioned(
                right: 16,
                bottom: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton(
                      heroTag: 'start_nav',
                      backgroundColor: Colors.green,
                      onPressed: _startNavigation,
                      child: const Icon(Icons.navigation),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton(
                      heroTag: 'stop_nav',
                      backgroundColor: Colors.red,
                      onPressed: _stopNavigation,
                      child: const Icon(Icons.stop),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton(
                      heroTag: 'load_route',
                      backgroundColor: const Color.fromARGB(255, 161, 133, 40),
                      onPressed: _loadRoute,
                      child: const Icon(Icons.map),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────
// Extracted so the main build method stays readable.
// Each widget is purely presentational — no controller access.

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

/* class _DebugOverlay extends StatelessWidget {
  final int polylinePoints;
  final ll.LatLng? position;
  final RoutingStatus status;
  final LocationStatus locationStatus;

  const _DebugOverlay({
    required this.polylinePoints,
    required this.position,
    required this.status,
    required this.locationStatus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Route: $polylinePoints pts',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
          if (position != null)
            Text(
              'GPS: ${position!.latitude.toStringAsFixed(5)}, '
              '${position!.longitude.toStringAsFixed(5)}',
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            )
          else
            const Text(
              'GPS: Waiting...',
              style: TextStyle(color: Colors.orange, fontSize: 10),
            ),
          Text(
            'Routing: ${status.name}',
            style: TextStyle(
              color: status == RoutingStatus.active
                  ? Colors.green
                  : status == RoutingStatus.rerouting
                  ? Colors.orange
                  : status == RoutingStatus.error
                  ? Colors.red
                  : Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'Location: ${locationStatus.name}',
            style: TextStyle(
              color: locationStatus == LocationStatus.active
                  ? Colors.green
                  : Colors.orange,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
} */
