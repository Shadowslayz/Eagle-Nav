import 'dart:async';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter/material.dart';

class CompassService {
  double _heading = 0;
  final ValueNotifier<double> headingNotifier = ValueNotifier(0);
  StreamSubscription<CompassEvent>? _subscription;

  void start() {
    _subscription = FlutterCompass.events?.listen((CompassEvent event) {
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
    _subscription?.cancel();
    headingNotifier.dispose();
  }
}
