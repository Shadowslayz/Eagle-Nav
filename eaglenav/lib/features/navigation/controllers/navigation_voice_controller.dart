import 'dart:async';
import 'package:eaglenav/features/navigation/services/navigation_instruction_enhancer.dart';
import 'package:eaglenav/features/navigation/services/off_course_detector.dart';
import 'package:eaglenav/features/navigation/services/orientation_coach.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../utils/bearing_utils.dart';
import '../services/compass_service.dart';
import '../services/tts_manager.dart';
import '../services/landmark_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  NAVIGATION VOICE CONTROLLER
// ─────────────────────────────────────────────────────────────────────────────

class NavigationVoiceController extends ChangeNotifier {
  late final CompassService _compass;
  late final TtsManager ttsManager;
  late final NavigationInstructionEnhancer _enhancer;
  late final OrientationCoach _coach;
  late final OffCourseDetector _offCourse;
  late final LandmarkService _landmarks;

  double _lastAnnouncedDistance = double.infinity;
  String _lastSpokenText = '';

  String _lastDisplayText = '';
  String get lastDisplayText => _lastDisplayText;

  NavigationVoiceController() {
    _compass = CompassService();
    ttsManager = TtsManager();
    _enhancer = NavigationInstructionEnhancer(_compass);
    _landmarks = LandmarkService();

    _coach = OrientationCoach(
      _compass,
      ttsManager,
      isBusy: () => ttsManager.isBusy,
    );
    _offCourse = OffCourseDetector(ttsManager, isBusy: () => ttsManager.isBusy);
  }

  Future<void> initialize() async {
    _compass.start();
    await ttsManager.initialize();
    await _landmarks.load();
  }

  // ── Step announcement ─────────────────────────────────────

  Future<void> announceStep({
    required String valhallaInstruction,
    required int maneuverType,
    required double distanceMeters,
    required LatLng stepEndLocation,
    required LatLng currentPosition,
    required List<LatLng> routePolyline,
    required String streetName,
    String? nextStreetName,
    String? roundaboutExitCount,
    String? nextTurnDirection,
    String? nextTurnStreetName,
  }) async {
    _offCourse.deactivate();
    _coach.stop();
    _lastAnnouncedDistance = double.infinity;

    final instruction = _enhancer.enhance(
      valhallaInstruction: valhallaInstruction,
      maneuverType: maneuverType,
      distanceMeters: distanceMeters,
      stepEndLocation: stepEndLocation,
      currentLocation: currentPosition,
      routePolyline: routePolyline,
      streetName: streetName,
      nextStreetName: nextStreetName,
      roundaboutExitCount: roundaboutExitCount,
    );

    // Update display text and notify UI
    _lastDisplayText = instruction.displayText;
    _lastSpokenText = instruction.spokenText;
    notifyListeners(); // ← triggers banner rebuild in ListenableBuilder

    await ttsManager.speak(instruction.spokenText, TtsPriority.high);

    if (instruction.requiresOrientationCheck) {
      _coach.startGuiding(
        targetBearing: instruction.targetBearing,
        streetName: streetName,
        onAligned: () => _offCourse.activate(),
      );
    } else {
      _offCourse.activate();
    }
  }

  // ── Distance countdown ────────────────────────────────────

  Future<void> onDistanceUpdate(
    double remainingMeters, {
    String? upcomingTurnDirection,
    String? upcomingStreetName,
  }) async {
    // No next turn means we're on the last step — don't announce a countdown
    if (upcomingTurnDirection == null) return;

    const thresholds = [30.0, 15.0, 8.0];

    for (final threshold in thresholds) {
      if (remainingMeters <= threshold && _lastAnnouncedDistance > threshold) {
        _lastAnnouncedDistance = threshold;

        final steps = BearingUtils.metersToSteps(remainingMeters);
        final turn = upcomingTurnDirection;
        final street =
            upcomingStreetName != null && upcomingStreetName.isNotEmpty
            ? ' onto $upcomingStreetName'
            : '';

        String alert;
        if (threshold <= 8) {
          alert = 'In about $steps steps, $turn$street.';
        } else if (threshold <= 15) {
          alert = 'Get ready to $turn$street in $steps steps.';
        } else {
          alert = 'In $steps steps, $turn$street.';
        }

        await ttsManager.speak(alert, TtsPriority.low);
        break;
      }
    }
  }

  // ── Deviation monitoring ──────────────────────────────────

  Future<void> onDeviationUpdate(double deviationMeters) async {
    await _offCourse.onDeviation(deviationMeters);
  }

  // ── On-demand ─────────────────────────────────────────────

  Future<void> repeatLastInstruction() async {
    final text = _lastSpokenText.isEmpty
        ? 'No instruction available yet.'
        : _lastSpokenText;
    await ttsManager.speak(text, TtsPriority.high);
  }

  Future<void> announceCurrentHeading({
    LatLng? currentPosition,
    String? currentStreetName,
    bool isOnRoute = true,
  }) async {
    final heading = _compass.currentHeading;
    final cardinal = CompassService.cardinalFromBearing(heading);

    final parts = <String>[];

    final path = (currentStreetName != null && currentStreetName.isNotEmpty)
        ? currentStreetName
        : 'the path';
    parts.add('You are on $path, heading $cardinal.');

    if (isOnRoute) {
      parts.add('You are on the correct path.');
    } else {
      parts.add('Warning — you may be off the route.');
    }

    if (currentPosition != null) {
      final nearby = _landmarks.findNearby(currentPosition, heading);
      if (nearby.isEmpty) {
        parts.add('No landmarks nearby.');
      } else {
        for (final landmark in nearby) {
          parts.add('${landmark.name} is ${landmark.relativeDirection}.');
        }
      }
    }

    await ttsManager.speak(parts.join(' '), TtsPriority.high);
  }

  // ── Lifecycle ─────────────────────────────────────────────

  Future<void> stop() async {
    _offCourse.deactivate();
    _coach.stop();
    _lastAnnouncedDistance = double.infinity;
    await ttsManager.stop();
  }

  @override
  Future<void> dispose() async {
    _offCourse.deactivate();
    _coach.stop();
    _compass.dispose();
    await ttsManager.dispose();
    super.dispose();
  }

  // ── Exposed notifiers ─────────────────────────────────────
  double get currentHeading => _compass.currentHeading;
  ValueNotifier<double> get compassHeadingNotifier => _compass.headingNotifier;
}
