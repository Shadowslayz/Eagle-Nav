import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart' as ll;
//import 'package:timezone/timezone.dart';
import '../services/location_service.dart';
import '../../routing/valhalla_service.dart';
import 'dart:async';

class MapStateController extends ChangeNotifier {
  // location service provides: permissions, GPS location, location updates
  final LocationService _locationService;
  final String _valhallaBaseUrl;

  ll.LatLng? currentLocation;
  List<ll.LatLng> routePolyline = [];
  bool isLoading = false;
  bool locationPermissionGranted = false;
  String? errorMessage;

  StreamSubscription<ll.LatLng>? _locationSubscription;

  MapStateController(this._locationService, this._valhallaBaseUrl);

  // --------------------Get Location -------------------------

  Future<LocationResult?> getLocation() async {
    debugPrint('Getting Location ...');
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      // Check if location services are enabled
      final serviceEnabled = await _locationService.isLocationServiceEnabled();

      if (!serviceEnabled) {
        debugPrint('Location services are disabled');
        isLoading = false;
        errorMessage = 'Location services are disabled';
        notifyListeners();
        return LocationResult.serviceDisabled;
      }

      // Check and request permission
      final permissionResult = await _locationService
          .checkAndRequestPermission();
      debugPrint('Permission state: $permissionResult');

      if (permissionResult == LocationPermissionResult.deniedForever) {
        debugPrint('Location permission denied forever.');
        isLoading = false;
        locationPermissionGranted = false;
        errorMessage =
            'Location permission denied. Please enable permission in settings.';
        notifyListeners();
        return LocationResult.permissionDeniedForever;
      }

      if (permissionResult == LocationPermissionResult.denied) {
        debugPrint('Location permission denied.');
        isLoading = false;
        locationPermissionGranted = false;
        errorMessage = 'Location permission denied.';
        notifyListeners();
        return LocationResult.permissionDenied;
      }

      // Permission granted
      if (permissionResult == LocationPermissionResult.granted) {
        debugPrint('Location permission granted');
        notifyListeners();

        // Get current position
        final location = await _locationService.getCurrentLocation();

        if (location != null) {
          currentLocation = location;
          debugPrint(
            'Initial position: ${location.latitude}, ${location.longitude}',
          );
        } else {
          errorMessage = 'Failed to get current position';
        }

        // update state after obtaining position
        isLoading = false;
        notifyListeners();

        // After location is obtained, location change is tracked live

        // Start location tracking stream
        startLocationTracking();

        return LocationResult.success;
      }
    } catch (e) {
      debugPrint('Error obtaining location: $e');
      isLoading = false;
      errorMessage = 'Error obtaining location: $e';
      notifyListeners();
      return LocationResult.error;
    }
    return null;
  }

  // Keep track and update current location
  void startLocationTracking() {
    debugPrint('Starting location tracking');

    _locationSubscription?.cancel(); // cancel existing subscription

    _locationSubscription = _locationService.getLocationStream().listen(
      (location) {
        currentLocation = location;
        notifyListeners();
      },
      onError: (error) {
        debugPrint('Location stream error: $error');
        errorMessage = 'Location tracking error: $error';
        notifyListeners();
      },
    );
  }

  // Stop listening to location updates
  void stopLocationTracking() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
  }

  // -------------------- Routing -------------------------

  /// Load route from current location to destination (for display only)
  Future<RouteResult> loadRoute(ll.LatLng destination) async {
    debugPrint('🗺️ Loading route...');

    if (currentLocation == null) {
      debugPrint('No current location available');
      errorMessage = 'Current location not available';
      notifyListeners();
      return RouteResult.noLocation;
    }

    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final start = currentLocation!;
      debugPrint('🛰️ Valhalla base: $_valhallaBaseUrl');
      debugPrint('🔍 Requesting route from $start to $destination');

      final route = await getValhallaRoute(
        valhallaBaseUrl: _valhallaBaseUrl,
        origin: start,
        destination: destination,
        costing: 'pedestrian',
      );

      if (route == null) {
        debugPrint('Failed to get route from Valhalla');
        isLoading = false;
        errorMessage = 'Failed to get route';
        notifyListeners();
        return RouteResult.failed;
      }

      debugPrint(
        'Got ${route.polyline.length} points, ${route.steps.length} steps',
      );

      routePolyline = route.polyline;
      isLoading = false;
      errorMessage = null;
      notifyListeners();

      return RouteResult.success;
    } catch (e) {
      debugPrint('Failed to load route: $e');
      isLoading = false;
      errorMessage = 'Failed to load route: $e';
      notifyListeners();
      return RouteResult.error;
    }
  }

  /// Get route for navigation (returns the route object for turn-by-turn)
  Future<NavigationRouteResult> getNavigationRoute(
    ll.LatLng destination,
  ) async {
    debugPrint('🧭 Getting navigation route...');

    // Ensure we have current location
    if (currentLocation == null) {
      // Try to get it immediately
      if (locationPermissionGranted) {
        final location = await _locationService.getCurrentLocation();
        if (location != null) {
          currentLocation = location;
          notifyListeners();
        } else {
          debugPrint('Failed to get current position');
          return NavigationRouteResult(
            result: RouteResult.noLocation,
            route: null,
          );
        }
      } else {
        debugPrint('Location permission not granted');
        return NavigationRouteResult(
          result: RouteResult.permissionDenied,
          route: null,
        );
      }
    }

    // Still no location
    if (currentLocation == null) {
      debugPrint('Still waiting for GPS location');
      return NavigationRouteResult(result: RouteResult.noLocation, route: null);
    }

    try {
      final start = currentLocation!;
      debugPrint('Getting route from $start to $destination');

      final route = await getValhallaRoute(
        valhallaBaseUrl: _valhallaBaseUrl,
        origin: start,
        destination: destination,
        costing: 'pedestrian',
      );

      if (route == null) {
        debugPrint('Failed to get navigation route');
        return NavigationRouteResult(result: RouteResult.failed, route: null);
      }

      debugPrint('Navigation route: ${route.steps.length} steps');

      // Update the polyline for display
      routePolyline = route.polyline;
      notifyListeners();

      return NavigationRouteResult(result: RouteResult.success, route: route);
    } catch (e) {
      debugPrint('Failed to get navigation route: $e');
      return NavigationRouteResult(result: RouteResult.error, route: null);
    }
  }

  /// Clear the current route
  void clearRoute() {
    routePolyline = [];
    notifyListeners();
  }

  @override
  void dispose() {
    stopLocationTracking();
    super.dispose();
  }
}

/// Result of location initialization
enum LocationResult {
  success,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  error,
}

/// Result of route loading
enum RouteResult { success, failed, noLocation, permissionDenied, error }

/// Result with route data for navigation
class NavigationRouteResult {
  final RouteResult result;
  final ValhallaRoute? route;

  NavigationRouteResult({required this.result, required this.route});
}
