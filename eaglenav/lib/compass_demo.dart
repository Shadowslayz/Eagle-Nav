import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';

class CompassDemo {
  StreamSubscription<CompassEvent>? _subscription;

  // get compass updates
  void start() {
    // listen to compass sensor events
    _subscription = FlutterCompass.events?.listen((CompassEvent event) {
      // heading in degrees
      final double? heading = event.heading;

      // heading is null
      if (heading == null) {
        debugPrint("Compass heading is null (sensor unavailable)");
        return;
      }
      // print degree
      debugPrint("Degree: ${heading.toStringAsFixed(2)}°");
    });
  }

  // stop compass updates
  void stop() {
    _subscription?.cancel();
  }
}
