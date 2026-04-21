import 'dart:async'; // 1. Added dart:async
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter/material.dart';

class CompassService {
  double _heading = 0;
  final ValueNotifier<double> headingNotifier = ValueNotifier(0);

  // 2. Added the subscription variable
  StreamSubscription<CompassEvent>? _compassSubscription;

  void start() {
    // FlutterCompass handles tilt compensation automatically:
    //   iOS  → wraps CLHeading (Apple's fused sensor stack)
    //   Android → fuses magnetometer + accelerometer + gyroscope via SensorManager
    // CompassEvent.heading is already a true north-referenced heading in degrees.
    // It returns null if the device has no magnetometer — guard against that.

    // 3. Saved the listener to the variable
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      final heading = event.heading;
      if (heading == null) return; // device doesn't support compass
      _heading = (heading + 360) % 360; // normalise to 0–360
      headingNotifier.value = _heading;
    });
  }

  double get currentHeading => headingNotifier.value;

  /// Returns a cardinal direction string from a bearing.
  static String cardinalFromBearing(double bearing) {
    const directions = [
      'north',
      'north-northeast',
      'northeast',
      'east-northeast',
      'east',
      'east-southeast',
      'southeast',
      'south-southeast',
      'south',
      'south-southwest',
      'southwest',
      'west-southwest',
      'west',
      'west-northwest',
      'northwest',
      'north-northwest',
    ];
    final index = ((bearing + 11.25) / 22.5).floor() % 16;
    return directions[index];
  }

  void dispose() {
    // 4. Cancel the stream BEFORE disposing the notifier
    _compassSubscription?.cancel();
    headingNotifier.dispose();
  }
}
