import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../services/speech.dart';
import '../services/haptics.dart';
import '../routing/services/valhalla_service.dart';

/// ─── GuidanceController ──────────────────────────────────────────────────────
///
/// Owns the turn-by-turn guidance layer on top of an active route.
/// Receives location ticks and drives step progression, TTS announcements,
/// and haptic feedback. Exposes reactive state for the UI (turn panel,
/// progress bar, arrival screen).
///
/// Responsibilities:
///   - Track which step the user is currently on
///   - Announce upcoming steps via Speech and Haptics at [announceTriggerMeters]
///   - Detect arrival and notify listeners
///   - Expose current step, next step, progress, and distance to next turn
///
/// Does NOT:
///   - Fetch or re-fetch routes (that is RoutingController's job)
///   - Know about GPS streams or location permissions
///   - Hold a reference to RoutingController directly
///
/// How it fits in:
///   RoutingController calls startNavigation() when a new route is applied
///   (initial or reroute). The navigation screen pushes location ticks into
///   onLocationUpdate() on every GPS tick alongside the deviation value
///   already computed by RoutingController — so distance is only calculated once.
/// ─────────────────────────────────────────────────────────────────────────────

class GuidanceController extends ChangeNotifier {
  final Speech _speech;
  final Haptics _haptics;

  // ── Config ────────────────────────────────────────────────
  /// Distance in meters at which an upcoming step is announced.
  final double announceTriggerMeters;

  /// Distance in meters at which the current step is considered passed
  /// and the controller advances to the next one.
  final double stepCompleteMeters;

  // ── State ─────────────────────────────────────────────────
  ValhallaRoute? _currentRoute;
  int _currentStepIndex = 0;
  bool _hasArrived = false;

  /// Tracks which step indices have already been announced so we
  /// never fire the same announcement twice for the same step.
  final Set<int> _announcedSteps = {};

  GuidanceController({
    Speech? speech,
    Haptics? haptics,
    this.announceTriggerMeters = 30.0,
    this.stepCompleteMeters = 10.0,
  }) : _speech = speech ?? Speech(),
       _haptics = haptics ?? Haptics();

  // ── Public state ──────────────────────────────────────────
  bool get isNavigating => _currentRoute != null && !_hasArrived;
  bool get hasArrived => _hasArrived;

  /// The step the user is currently approaching.
  NavigationStep? get currentStep {
    if (_currentRoute == null) return null;
    if (_currentStepIndex >= _currentRoute!.steps.length) return null;
    return _currentRoute!.steps[_currentStepIndex];
  }

  /// The step after the current one — useful for "then turn..." in the UI.
  NavigationStep? get nextStep {
    if (_currentRoute == null) return null;
    final nextIndex = _currentStepIndex + 1;
    if (nextIndex >= _currentRoute!.steps.length) return null;
    return _currentRoute!.steps[nextIndex];
  }

  /// 0.0 → 1.0 progress through the step list.
  double get progress {
    if (_currentRoute == null || _currentRoute!.steps.isEmpty) return 0.0;
    return _currentStepIndex / _currentRoute!.steps.length;
  }

  // ── Route lifecycle ───────────────────────────────────────

  /// Start (or restart) guidance on a new route.
  /// Called by the navigation screen whenever RoutingController emits a new
  /// route — covers both the initial fetch and any reroute.
  void startNavigation(ValhallaRoute route) {
    _currentRoute = route;
    _currentStepIndex = 0;
    _hasArrived = false;
    _announcedSteps.clear();
    notifyListeners();

    // Announce the first instruction immediately so the user knows
    // navigation has started without waiting to approach the first turn.
    if (route.steps.isNotEmpty) {
      _announceStep(route.steps[0]);
    }
  }

  /// Stop guidance and clear all state. Called when the user cancels
  /// navigation or the navigation screen is disposed.
  void stopNavigation() {
    _currentRoute = null;
    _currentStepIndex = 0;
    _hasArrived = false;
    _announcedSteps.clear();
    notifyListeners();
  }

  // ── Location updates ──────────────────────────────────────

  /// Called on every GPS tick from the navigation screen.
  /// [position] is the user's current location.
  /// [deviationMeters] is passed in from RoutingController so we don't
  /// recompute the distance-to-route calculation a second time.
  void onLocationUpdate(ll.LatLng position, {double? deviationMeters}) {
    if (_currentRoute == null || _hasArrived) return;

    final steps = _currentRoute!.steps;
    if (steps.isEmpty) return;

    // Walk forward from the current step index checking upcoming steps.
    // We only look ahead a bounded window to avoid over-advancing on a
    // long straight segment that passes close to a future turn point.
    final lookAheadLimit = (_currentStepIndex + 3).clamp(0, steps.length);

    for (int i = _currentStepIndex; i < lookAheadLimit; i++) {
      final step = steps[i];
      final distance = _calculateDistance(position, step.location);
      final isLastStep = i == steps.length - 1;

      // ── Arrival detection ──────────────────────────────
      // Treat the last step reaching stepCompleteMeters as arrival.
      if (isLastStep && distance <= stepCompleteMeters) {
        _handleArrival(step);
        return;
      }

      // ── Step announcement ──────────────────────────────
      // Announce when close enough and not yet announced.
      if (distance <= announceTriggerMeters && !_announcedSteps.contains(i)) {
        _announceStep(step);
        _announcedSteps.add(i);
        // Don't break — allow the loop to also check if we've passed this step.
      }

      // ── Step completion ────────────────────────────────
      // Advance index once the user has clearly passed the step location.
      // Only advance the *current* index (i == _currentStepIndex) to avoid
      // skipping multiple steps in one tick.
      if (distance < stepCompleteMeters && i == _currentStepIndex) {
        _currentStepIndex = i + 1;
        notifyListeners();
        break;
      }
    }
  }

  // ── Internals ─────────────────────────────────────────────

  Future<void> _handleArrival(NavigationStep arrivalStep) async {
    _hasArrived = true;
    notifyListeners();
    await _announceStep(arrivalStep);
  }

  /// Fire haptics first (instant) then TTS (slight delay) so the physical
  /// feedback always lands before the spoken instruction.
  Future<void> _announceStep(NavigationStep step) async {
    debugPrint(' ${step.instruction}');

    final hapticEvent = Haptics.fromKind(step.getHapticKind());
    await Haptics.fire(hapticEvent);
    await _speech.announceDirection(step.getTTSInstruction());
  }

  double _calculateDistance(ll.LatLng a, ll.LatLng b) {
    const ll.Distance distance = ll.Distance();
    return distance.as(ll.LengthUnit.Meter, a, b);
  }
}
