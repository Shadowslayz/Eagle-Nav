// Get user location via GPS and handle permissions
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:flutter/material.dart';
//import 'package:flutter/widgets.dart';
//import 'package:flutter/foundation.dart';

class LocationService {
  // Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  // ------Location Permission Handling and Initialization ------
  // Check and request location permissions
  // Returns true if permission granted, false otherwise
  Future<LocationPermissionResult> checkAndRequestPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    debugPrint('Current permission status: $permission');

    if (permission == LocationPermission.denied) {
      // Ask for permission
      debugPrint('Requesting location permission...');
      permission = await Geolocator.requestPermission();
      debugPrint('Permission after request: $permission');
    }

    // Return response for denied and forever denied permissions
    if (permission == LocationPermission.deniedForever) {
      debugPrint('Permission denied forever');
      return LocationPermissionResult.deniedForever;
    }

    if (permission == LocationPermission.denied) {
      debugPrint('Permission denied');

      return LocationPermissionResult.denied;
    }

    // return once permission is granted
    debugPrint('Permission granted');
    return LocationPermissionResult.granted;
  }

  // Get GPS Location
  Future<ll.LatLng?> getCurrentLocation() async {
    try {
      // Define LocationSettings with high accuracy
      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 100,
        timeLimit: Duration(seconds: 15), // Add timeout to prevent hanging
      );

      debugPrint('Getting current position...');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );

      debugPrint('Got position: ${position.latitude}, ${position.longitude}');
      return ll.LatLng(position.latitude, position.longitude);
    } catch (e) {
      debugPrint('Failed to get current position: $e');
      return null;
    }
  }

  // Stream of location updates
  Stream<ll.LatLng> getLocationStream({
    LocationAccuracy accuracy = LocationAccuracy.high,
    int distanceFilter = 5,
  }) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
      ),
    ).map((position) {
      debugPrint(
        'Live location update: ${position.latitude}, ${position.longitude}',
      );
      return ll.LatLng(position.latitude, position.longitude);
    });
  }
}

// Result of permission check
enum LocationPermissionResult { granted, denied, deniedForever }
