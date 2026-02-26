import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../services/location_service.dart';

enum LocationStatus {
  idle,
  loading,
  active,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  error,
}

class LocationController extends ChangeNotifier {
  final LocationService _locationService;

  ll.LatLng? _currentLocation;
  LocationStatus _status = LocationStatus.idle;
  String? _errorMessage;
  StreamSubscription<ll.LatLng>? _locationSubscription;

  LocationController(this._locationService);

  // ── Public state ──────────────────────────────────────────
  ll.LatLng? get currentLocation => _currentLocation;
  LocationStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get isActive => _status == LocationStatus.active;

  // ── Initialization ────────────────────────────────────────
  Future<void> initialize() async {
    _setStatus(LocationStatus.loading);

    final serviceEnabled = await _locationService.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _setStatus(
        LocationStatus.serviceDisabled,
        error: 'Location services are disabled',
      );
      return;
    }

    final permission = await _locationService.checkAndRequestPermission();

    switch (permission) {
      case LocationPermissionResult.deniedForever:
        _setStatus(
          LocationStatus.permissionDeniedForever,
          error:
              'Location permission permanently denied. Please enable it in settings.',
        );
        return;
      case LocationPermissionResult.denied:
        _setStatus(
          LocationStatus.permissionDenied,
          error: 'Location permission denied.',
        );
        return;
      case LocationPermissionResult.granted:
        break;
    }

    final location = await _locationService.getCurrentLocation();
    if (location == null) {
      _setStatus(LocationStatus.error, error: 'Failed to get current location');
      return;
    }

    _currentLocation = location;
    _setStatus(LocationStatus.active);
    _startTracking();
  }

  // ── Tracking ──────────────────────────────────────────────
  void _startTracking() {
    _locationSubscription?.cancel();
    _locationSubscription = _locationService.getLocationStream().listen(
      (location) {
        _currentLocation = location;
        notifyListeners();
      },
      onError: (error) {
        _setStatus(
          LocationStatus.error,
          error: 'Location tracking error: $error',
        );
      },
    );
  }

  void stopTracking() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
  }

  // ── Helpers ───────────────────────────────────────────────
  void _setStatus(LocationStatus status, {String? error}) {
    _status = status;
    _errorMessage = error;
    notifyListeners();
  }

  @override
  void dispose() {
    stopTracking();
    super.dispose();
  }
}
