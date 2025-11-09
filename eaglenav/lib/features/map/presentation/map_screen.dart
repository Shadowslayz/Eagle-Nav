import 'package:eaglenav/features/map/controllers/map_state_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
//import 'package:geolocator/geolocator.dart';
//import 'package:timezone/timezone.dart';
import '/config/app_config.dart';
import '../services/location_service.dart';
//import '../../routing/valhalla_service.dart';
import '../../routing/controller/navigation_controller.dart';

class MapTestScreen extends StatelessWidget {
  const MapTestScreen({super.key});
  static final GlobalKey<_SimpleMapState> _mapKey =
      GlobalKey<_SimpleMapState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map Test Mode'),
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
      ),
      body: RepaintBoundary(child: SimpleMap(key: MapTestScreen._mapKey)),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Start navigation button
            FloatingActionButton(
              heroTag: 'start_nav',
              backgroundColor: Colors.green,
              onPressed: () async {
                print('Start navigation button pressed');
                await _mapKey.currentState?._startNavigation();
              },
              child: const Icon(Icons.navigation),
            ),
            const SizedBox(height: 10),
            // Stop navigation button
            FloatingActionButton(
              heroTag: 'stop_nav',
              backgroundColor: Colors.red,
              onPressed: () {
                print('Stop navigation button pressed');
                _mapKey.currentState?._stopNavigation();
              },
              child: const Icon(Icons.stop),
            ),
            const SizedBox(height: 10),
            // Load route button
            FloatingActionButton(
              heroTag: 'load_route',
              backgroundColor: const Color.fromARGB(255, 161, 133, 40),
              onPressed: () async {
                print('🟡 Load route button pressed');
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Loading route...'),
                    duration: Duration(seconds: 2),
                  ),
                );
                await _mapKey.currentState?._loadRoute();
              },
              child: const Icon(Icons.map),
            ),
          ],
        ),
      ),
    );
  }
}

class SimpleMap extends StatefulWidget {
  const SimpleMap({super.key});

  @override
  State<SimpleMap> createState() => _SimpleMapState();
}

class _SimpleMapState extends State<SimpleMap> {
  // flutter_map's controller
  late MapController mapController;

  // Map state controller
  late MapStateController _stateController;
  final NavigationController _navController = NavigationController();

  String? _currentInstruction;
  double? _distanceToNextTurn;
  bool _isNavigating = false;

  // Default destination (you can make this dynamic later)
  final _destination = const ll.LatLng(34.06754331506277, -118.16664572292852);

  @override
  void initState() {
    super.initState();
    mapController = MapController();
    _stateController = MapStateController(
      LocationService(),
      AppConfig.valhallaBaseUrl,
    );

    debugPrint('🔧 MapTestScreen initialized');
    _getLocation();

    // Listen to location updates for navigation
    _listenToLocationUpdates();
  }

  /// Initialize location and handle UI responses
  Future<void> _getLocation() async {
    final locationResult = await _stateController.getLocation();

    if (!mounted) return;

    switch (locationResult) {
      case LocationResult.serviceDisabled:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enable location.'),
            duration: Duration(seconds: 3),
          ),
        );
        break;
      case LocationResult.permissionDenied:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission denied.'),
            duration: Duration(seconds: 3),
          ),
        );
        break;
      case LocationResult.permissionDeniedForever:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission denied. Enable in settings.'),
            duration: Duration(seconds: 4),
          ),
        );
        break;
      case LocationResult.success:
        if (_stateController.currentLocation != null) {
          mapController.move(_stateController.currentLocation!, 16.0);
        }
        break;
      case LocationResult.error:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_stateController.errorMessage ?? 'Unknown error'),
            duration: const Duration(seconds: 3),
          ),
        );
        break;
      case null:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No location data received'),
            duration: const Duration(seconds: 3),
          ),
        );
        break;
    }
  }

  /// Listen to location updates for navigation
  void _listenToLocationUpdates() {
    _stateController.addListener(() {
      if (_isNavigating &&
          _stateController.currentLocation != null &&
          _navController.isNavigating) {
        final location = _stateController.currentLocation!;

        // Update navigation controller
        _navController.updateLocation(location);

        // Update UI state
        setState(() {
          _currentInstruction = _navController.getCurrentInstruction();
          _distanceToNextTurn = _navController.getDistanceToNextTurn(location);
        });

        // Keep map centered on user during navigation
        if (mounted) {
          mapController.move(location, mapController.camera.zoom);
        }
      }
    });
  }

  /// Load route and display on map (without starting navigation)
  Future<void> _loadRoute() async {
    debugPrint('🗺️ Load route button pressed');

    final result = await _stateController.loadRoute(_destination);

    if (!mounted) return;

    switch (result) {
      case RouteResult.success:
        // Fit camera to route
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _stateController.routePolyline.length < 2) return;
          final bounds = LatLngBounds.fromPoints(
            _stateController.routePolyline,
          );
          mapController.fitCamera(
            CameraFit.bounds(
              bounds: bounds,
              padding: const EdgeInsets.all(100),
              maxZoom: 15,
            ),
          );
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Route loaded!'),
            duration: Duration(seconds: 2),
          ),
        );
        break;

      case RouteResult.noLocation:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Waiting for GPS location...'),
            duration: Duration(seconds: 2),
          ),
        );
        break;

      case RouteResult.failed:
      case RouteResult.error:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _stateController.errorMessage ?? 'Failed to load route',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        break;

      case RouteResult.permissionDenied:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission required'),
            duration: Duration(seconds: 2),
          ),
        );
        break;
    }
  }

  /// Start turn-by-turn navigation with TTS and haptics
  Future<void> _startNavigation() async {
    debugPrint('Start navigation button pressed');

    final navResult = await _stateController.getNavigationRoute(_destination);

    if (!mounted) return;

    switch (navResult.result) {
      case RouteResult.success:
        if (navResult.route == null) {
          debugPrint('Route is null despite success');
          return;
        }

        setState(() {
          _isNavigating = true;
        });

        // Start navigation controller (triggers TTS + haptics)
        _navController.startNavigation(navResult.route!);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Navigation started!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        break;

      case RouteResult.noLocation:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Still waiting for GPS location...'),
            duration: Duration(seconds: 2),
          ),
        );
        break;

      case RouteResult.permissionDenied:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission not granted'),
            duration: Duration(seconds: 2),
          ),
        );
        break;

      case RouteResult.failed:
      case RouteResult.error:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Navigation error: ${_stateController.errorMessage ?? "Unknown error"}',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        break;
    }
  }

  /// Stop navigation
  void _stopNavigation() {
    debugPrint('Stop navigation button pressed');

    _navController.stopNavigation();
    setState(() {
      _isNavigating = false;
      _currentInstruction = null;
      _distanceToNextTurn = null;
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Navigation stopped'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  @override
  void dispose() {
    _navController.stopNavigation();
    _stateController.dispose();
    mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _stateController,
      builder: (context, child) {
        return Stack(
          children: [
            // Map
            FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter:
                    _stateController.currentLocation ??
                    const ll.LatLng(34.067, -118.170),
                initialZoom: 16.0,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.eagle_nav_app',
                  maxZoom: 19.0,
                  minZoom: 12.0,
                ),
                // Route polyline - now from controller
                PolylineLayer(
                  polylines: [
                    if (_stateController.routePolyline.isNotEmpty)
                      Polyline(
                        points: _stateController.routePolyline,
                        strokeWidth: 4,
                        color: _isNavigating ? Colors.blue : Colors.grey,
                      ),
                  ],
                ),
                // Markers
                MarkerLayer(
                  markers: [
                    // Current location marker - from controller
                    if (_stateController.currentLocation != null)
                      Marker(
                        point: _stateController.currentLocation!,
                        width: 50,
                        height: 50,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.8),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                          child: const Icon(
                            Icons.navigation,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    // Start marker - from controller
                    if (_stateController.routePolyline.isNotEmpty)
                      Marker(
                        point: _stateController.routePolyline.first,
                        width: 40,
                        height: 40,
                        child: const Icon(
                          Icons.location_on,
                          color: Colors.green,
                          size: 40,
                        ),
                      ),
                    // End marker - from controller
                    if (_stateController.routePolyline.isNotEmpty)
                      Marker(
                        point: _stateController.routePolyline.last,
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

            // Navigation instruction banner
            if (_currentInstruction != null && _isNavigating)
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Card(
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
                                _currentInstruction!,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_distanceToNextTurn != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'in ${_distanceToNextTurn!.toStringAsFixed(0)} meters',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 16,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

            // Debug info - updated to use controller
            Positioned(
              bottom: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Route: ${_stateController.routePolyline.length} pts',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    if (_stateController.currentLocation != null)
                      Text(
                        'GPS: ${_stateController.currentLocation!.latitude.toStringAsFixed(5)}, '
                        '${_stateController.currentLocation!.longitude.toStringAsFixed(5)}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      )
                    else
                      const Text(
                        'GPS: Waiting...',
                        style: TextStyle(color: Colors.orange, fontSize: 10),
                      ),
                    Text(
                      _isNavigating ? 'Navigating' : 'Ready to navigate',
                      style: TextStyle(
                        color: _isNavigating ? Colors.green : Colors.orange,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Permission: ${_stateController.locationPermissionGranted ? "Sucess" : "Failed"}',
                      style: TextStyle(
                        color: _stateController.locationPermissionGranted
                            ? Colors.green
                            : Colors.red,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
