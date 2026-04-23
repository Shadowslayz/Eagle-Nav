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

  // Stream of location updates, filtered by accuracy.
  //
  // Fixes with OS-reported accuracy worse than [maxAccuracyMeters] are
  // dropped before entering the controller pipeline. On a campus with
  // buildings around the user, GPS multipath can produce fixes with
  // 20m+ error bars — these do more harm than good to threshold-based
  // step-advance and turn-now logic downstream.
  Stream<ll.LatLng> getLocationStream({
    LocationAccuracy accuracy = LocationAccuracy.high,
    int distanceFilter = 5,
    double maxAccuracyMeters = 20.0,
  }) {
    return Geolocator.getPositionStream(
          locationSettings: LocationSettings(
            accuracy: accuracy,
            distanceFilter: distanceFilter,
          ),
        )
        .where((position) {
          // accuracy field is non-nullable on geolocator's Position,
          // but treat 0.0 as "unknown" and let it through — some
          // platforms report 0 when they can't estimate the error.
          final acc = position.accuracy;
          if (acc > 0 && acc > maxAccuracyMeters) {
            debugPrint(
              'Dropping low-accuracy fix: ${acc.toStringAsFixed(1)}m '
              '(threshold ${maxAccuracyMeters.toStringAsFixed(0)}m)',
            );
            return false;
          }
          return true;
        })
        .map((position) {
          debugPrint(
            'Live location update: ${position.latitude}, ${position.longitude} '
            '(acc ${position.accuracy.toStringAsFixed(1)}m)',
          );
          return ll.LatLng(position.latitude, position.longitude);
        });
  }
}

// Result of permission check
enum LocationPermissionResult { granted, denied, deniedForever }
