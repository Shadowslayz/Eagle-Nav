import 'dart:async';
import 'package:eaglenav/features/navigation/services/navigation_instruction_enhancer.dart';
import 'package:eaglenav/features/navigation/services/off_course_detector.dart';
import 'package:eaglenav/features/navigation/services/orientation_coach.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../utils/bearing_utils.dart';
import '../services/compass_service.dart';
import '../services/tts_manager.dart';
import '../services/landmark_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  NAVIGATION VOICE CONTROLLER
// ─────────────────────────────────────────────────────────────────────────────
//
//  Owns all spoken output. Other controllers (Routing, Guidance) do not call
//  TTS directly — they fire callbacks that the screen routes here.
//
//  Layers of speech, in rough priority order:
//    1. announceApproachToPath — Phase 1 coaching onto the walkable network
//    2. announceStep           — full turn-by-turn instruction at step entry
//    3. announceTurnNow        — short cue at the moment of the turn
//    4. onDistanceUpdate       — countdown alerts on approach to a turn
//    5. onDeviationUpdate      — off-course warnings (suppressed when aligned)
//    6. announceCurrentHeading — on-demand status (double-tap / button)
//
// ─────────────────────────────────────────────────────────────────────────────

class NavigationVoiceController extends ChangeNotifier {
  late final CompassService _compass;
  late final TtsManager ttsManager;
  late final NavigationInstructionEnhancer _enhancer;
  late final OrientationCoach _coach;
  late final OffCourseDetector _offCourse;
  late final LandmarkService _landmarks;

  // ── State ─────────────────────────────────────────────────
  double _lastAnnouncedDistance = double.infinity;
  String _lastSpokenText = '';
  String _lastDisplayText = '';
  String get lastDisplayText => _lastDisplayText;

  // ── Phase 1 — off-network approach state ──────────────────
  ll.LatLng? _pathEntryPoint;
  bool _isApproachingPath = false;
  VoidCallback? _onPathReached;

  static const double _pathReachedThreshold = 15.0; // metres

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

  // ── Phase 1 — approach to path ────────────────────────────

  /// Called at navigation start when the user is not yet on the walkable network.
  /// Orients them toward the nearest path entry point using relative human directions.
  /// Calls [onReached] once the user arrives within [_pathReachedThreshold] metres.
  Future<void> announceApproachToPath({
    required ll.LatLng currentPosition,
    required ll.LatLng pathEntryPoint,
    required String streetName,
    required VoidCallback onReached,
  }) async {
    _pathEntryPoint = pathEntryPoint;
    _isApproachingPath = true;
    _onPathReached = onReached;

    final bearing = BearingUtils.bearingTo(currentPosition, pathEntryPoint);
    final relAngle = BearingUtils.relativeAngle(
      _compass.currentHeading,
      bearing,
    );
    final steps = BearingUtils.metersToSteps(
      BearingUtils.distanceBetween(currentPosition, pathEntryPoint),
    );

    final String turnInstruction = _relativeToHuman(relAngle);
    final name = streetName.isNotEmpty ? streetName : 'the walkway';

    await ttsManager.speak(
      'You are not yet on the path. '
      '$turnInstruction, then walk about $steps steps to reach $name. '
      'I will start guiding you once you are on the path.',
      TtsPriority.high,
    );

    // Orient compass cone toward path entry point
    _coach.startGuiding(
      targetBearing: bearing,
      streetName: streetName,
      onAligned: () => _offCourse.activate(),
    );
  }

  /// Called when RoutingController starts a reroute.
  /// Silences all corrections so they don't overlap with the reroute announcement.
  Future<void> onRerouting() async {
    _offCourse.deactivate();
    _coach.stop();
    _isApproachingPath = false;
    await ttsManager.speak('Rerouting.', TtsPriority.high);
  }

  /// Called on every GPS tick from the screen's _onLocationUpdate.
  /// Monitors progress toward the path entry point during Phase 1.
  /// Transitions to Phase 2 (normal navigation) once close enough.
  void onApproachUpdate(ll.LatLng currentPosition) {
    if (!_isApproachingPath || _pathEntryPoint == null) return;

    final remaining = BearingUtils.distanceBetween(
      currentPosition,
      _pathEntryPoint!,
    );

    if (remaining <= _pathReachedThreshold) {
      // User has reached the path — transition to Phase 2
      _isApproachingPath = false;
      _offCourse.deactivate();
      _coach.stop();

      final callback = _onPathReached;
      _pathEntryPoint = null;
      _onPathReached = null;

      callback?.call();
    }
  }

  // ── Human-readable relative direction ─────────────────────

  String _relativeToHuman(double relAngle) {
    final abs = relAngle.abs();
    final dir = relAngle > 0 ? 'right' : 'left';

    if (abs < 15) return 'Walk straight ahead';
    if (abs < 45) return 'Turn slightly to the $dir';
    if (abs < 100) return 'Turn to your $dir';
    if (abs < 150) return 'Turn sharply to your $dir';
    return 'Turn around and walk the opposite direction';
  }

  // ── Step announcement ─────────────────────────────────────

  /// The full turn-by-turn announcement, spoken at the moment the user
  /// crosses into a new step. Delegates phrasing to the enhancer and then
  /// resets deviation state so off-course warnings don't fire mid-speech.
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

    _lastDisplayText = instruction.displayText;
    _lastSpokenText = instruction.spokenText;
    notifyListeners();

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

  // ── Imminent turn cue ─────────────────────────────────────

  /// Short "turn now" cue fired the moment the user crosses into a new step
  /// whose maneuver is a real turn. Plays BEFORE [announceStep] so the user
  /// gets an immediate action trigger, then the fuller announcement follows
  /// with street name and distance context.
  ///
  /// Only fires for sharp-enough turns (right, sharp right, sharp left, left).
  /// Slight bears and roundabouts are left to [announceStep] alone because
  /// a "turn now" cue for a 15° slight bear sounds overcaffeinated.
  ///
  /// Unlike [announceStep], this method does NOT touch the off-course
  /// detector or the orientation coach — [announceStep] fires right after
  /// and will handle that state transition itself.
  Future<void> announceTurnNow({
    required int maneuverType,
    required String turnDirection,
  }) async {
    // Filter: only the four real turns.
    const turnManeuvers = {10, 11, 14, 15};
    if (!turnManeuvers.contains(maneuverType)) return;

    String phrase;
    switch (maneuverType) {
      case 10:
        phrase = 'Turn right now.';
        break;
      case 15:
        phrase = 'Turn left now.';
        break;
      case 11:
        phrase = 'Sharp right now.';
        break;
      case 14:
        phrase = 'Sharp left now.';
        break;
      default:
        phrase = '$turnDirection now.';
    }

    await ttsManager.speak(phrase, TtsPriority.high);
  }

  // ── Distance countdown ────────────────────────────────────

  Future<void> onDistanceUpdate(
    double remainingMeters, {
    String? upcomingTurnDirection,
    String? upcomingStreetName,
  }) async {
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

  /// Called on every GPS tick with the deviation distance from the route.
  ///
  /// [userIsAligned] is computed by the screen from the user's compass
  /// heading and the route bearing at the nearest segment. When true, the
  /// user is walking parallel to the path — typically on an adjacent
  /// sidewalk — and the off-course warning is suppressed to avoid nagging
  /// them while they're doing the right thing.
  ///
  /// The reroute decision itself is made by RoutingController using the
  /// same alignment signal; this suppression is purely about what the
  /// user *hears*, not about whether a reroute eventually fires.
  Future<void> onDeviationUpdate(
    double deviationMeters, {
    bool userIsAligned = false,
  }) async {
    if (userIsAligned) return;
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

    final parts = <String>[];

    // 1. Where they are — the most important piece of grounding info.
    final path = (currentStreetName != null && currentStreetName.isNotEmpty)
        ? currentStreetName
        : 'the path';
    parts.add('You are on $path.');

    // 2. What's around them — the new information a status check exists for.
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

    /*  // 3. Route-status reassurance — least new information, goes last so it
    //    doesn't push the landmarks further down the utterance.
    if (isOnRoute) {
      parts.add('You are on the correct path.');
    } else {
      parts.add('Warning — you may be off the route.');
    } */

    await ttsManager.speak(parts.join(' '), TtsPriority.high);
  }

  // ── Lifecycle ─────────────────────────────────────────────

  Future<void> stop() async {
    _isApproachingPath = false;
    _pathEntryPoint = null;
    _onPathReached = null;
    _offCourse.deactivate();
    _coach.stop();
    _lastAnnouncedDistance = double.infinity;
    await ttsManager.stop();
  }

  @override
  Future<void> dispose() async {
    _isApproachingPath = false;
    _pathEntryPoint = null;
    _onPathReached = null;
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
