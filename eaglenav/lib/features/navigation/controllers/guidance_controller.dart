import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../services/haptics.dart';
import '../routing/services/valhalla_service.dart';

/// ─── GuidanceController ──────────────────────────────────────────────────────
///
/// Owns the turn-by-turn guidance layer on top of an active route.
/// Receives location ticks and drives step progression and haptic feedback.
/// Exposes reactive state for the UI (turn panel, progress bar, arrival).
///
/// Responsibilities:
///   - Track which step the user is currently on
///   - Fire [onStepAdvanced] when the user passes a step — the screen owns
///     all TTS announcements via NavigationVoiceController
///   - Detect arrival and notify listeners
///   - Expose current step, next step, and progress
///
/// Does NOT:
///   - Fetch or re-fetch routes (that is RoutingController's job)
///   - Know about GPS streams or location permissions
///   - Speak any TTS directly — that is NavigationVoiceController's job
///   - Hold a reference to RoutingController directly
///
/// How it fits in:
///   RoutingController calls startNavigation() when a new route is applied
///   (initial or reroute). The navigation screen pushes location ticks into
///   onLocationUpdate() on every GPS tick alongside the deviation value
///   already computed by RoutingController — so distance is only calculated once.
/// ─────────────────────────────────────────────────────────────────────────────

class GuidanceController extends ChangeNotifier {
  final Haptics _haptics;

  /// Distance in meters at which the current step is considered passed
  /// and the controller advances to the next one.
  final double stepCompleteMeters;

  // ── State ─────────────────────────────────────────────────
  ValhallaRoute? _currentRoute;
  int _currentStepIndex = 0;
  bool _hasArrived = false;

  // ── Callbacks ─────────────────────────────────────────────
  // The screen wires these. The controller does not speak or haptic on its
  // own — it only fires callbacks so the voice layer stays independent.

  /// Called whenever the step index advances. The screen wires this to
  /// NavigationVoiceController.announceStep() so TTS fires on each new step.
  VoidCallback? onStepAdvanced;

  /// Called when the user reaches the destination. The screen uses this to
  /// tear down navigation state after the arrival TTS has a chance to finish.
  VoidCallback? onArrival;

  /// Called the moment the user crosses into a new step whose maneuver is
  /// a real turn (right, left, sharp right, sharp left). Fires BEFORE
  /// [onStepAdvanced] so the short "turn now" cue hits the TTS queue first.
  VoidCallback? onTurnImminent;

  GuidanceController({Haptics? haptics, this.stepCompleteMeters = 10.0})
    : _haptics = haptics ?? Haptics();

  // ── Public state ──────────────────────────────────────────

  bool get isNavigating => _currentRoute != null && !_hasArrived;
  bool get hasArrived => _hasArrived;

  /// The step the user is currently approaching.
  NavigationStep? get currentStep {
    if (_currentRoute == null) return null;
    if (_currentStepIndex >= _currentRoute!.steps.length) return null;
    return _currentRoute!.steps[_currentStepIndex];
  }

  /// The step after the current one — used for upcoming turn info in the UI
  /// and distance countdown alerts.
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
    notifyListeners();
  }

  /// Stop guidance and clear all state. Called when the user cancels
  /// navigation or the navigation screen is disposed.
  void stopNavigation() {
    _currentRoute = null;
    _currentStepIndex = 0;
    _hasArrived = false;
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

    // ── Global arrival check ──────────────────────────────
    // If the user is within a safe threshold of the total destination,
    // trigger arrival immediately — regardless of which step they're on.
    // This handles the case where GPS jumps them close to the goal without
    // cleanly advancing through the final step(s).
    final finalStep = steps.last;
    final distanceToDestination = _calculateDistance(
      position,
      finalStep.location,
    );

    if (distanceToDestination <= 15.0) {
      _handleArrival(finalStep);
      return;
    }

    // ── Step progression check ────────────────────────────
    // Look ahead a bounded window to avoid over-advancing on a long straight
    // segment that passes close to a future turn point.
    final lookAheadLimit = (_currentStepIndex + 3).clamp(0, steps.length);

    for (int i = _currentStepIndex; i < lookAheadLimit; i++) {
      final step = steps[i];
      final distanceToStepEnd = _calculateDistance(position, step.endLocation);
      final isLastStep = i == steps.length - 1;

      // Near-arrival catch: on the last or second-to-last step, if we're
      // close enough to the step endpoint, treat as arrival. Covers the
      // case where the global arrival check above didn't fire because the
      // destination and final step endpoint are slightly offset.
      if (i >= steps.length - 2 && distanceToStepEnd <= stepCompleteMeters) {
        _handleArrival(steps.last);
        return;
      }

      // Final-step arrival — redundant with the block above but preserved
      // for safety on routes where steps.length == 1.
      if (isLastStep && distanceToStepEnd <= stepCompleteMeters) {
        _handleArrival(step);
        return;
      }

      // Step completion — advance once the user clearly passed the step
      // endpoint. Only advance the current index (not look-ahead steps) to
      // avoid skipping multiple turns in one tick.
      if (distanceToStepEnd < stepCompleteMeters && i == _currentStepIndex) {
        _advanceStep(i + 1);
        break;
      }
    }
  }

  // ── Internals ─────────────────────────────────────────────

  /// Advance to [newIndex] and fire callbacks.
  ///
  /// Order matters: [onTurnImminent] fires BEFORE [onStepAdvanced] so the
  /// short "turn now" cue hits the TTS queue ahead of the fuller announcement.
  ///
  /// The imminent cue reads the NEWLY-ENTERED step's maneuver, not the
  /// completed one. Valhalla's maneuverType describes the action at the
  /// START of that step, which is the intersection the user is standing at
  /// right now — exactly when we want to say "turn right now".
  void _advanceStep(int newIndex) {
    _currentStepIndex = newIndex;
    notifyListeners();

    final newStep = _currentRoute!.steps[_currentStepIndex];
    final turn = newStep.getTurnDirection();

    // Skip arrival (type 4) — handled separately via _handleArrival.
    if (turn != null && newStep.maneuverType != 4) {
      onTurnImminent?.call();
    }

    onStepAdvanced?.call();
  }

  /// Finalise arrival — set the flag, fire haptic, play arrival announcement,
  /// then give TTS a moment to speak before tearing down navigation state.
  Future<void> _handleArrival(NavigationStep arrivalStep) async {
    if (_hasArrived) return; // prevent repeat calls on successive GPS ticks
    _hasArrived = true;

    // Force the controller to point exactly at the final step so when
    // onStepAdvanced fires, the screen reads the "arrival" maneuver
    // (type 4, 5, or 6) and passes it to the enhancer.
    _currentStepIndex = _currentRoute!.steps.indexOf(arrivalStep);

    notifyListeners();
    debugPrint('Arrival: ${arrivalStep.instruction}');

    final hapticEvent = Haptics.fromKind(arrivalStep.getHapticKind());
    await Haptics.fire(hapticEvent);

    onStepAdvanced?.call();

    // Small delay so the arrival TTS has a chance to queue before the
    // screen tears down navigation state on the onArrival callback.
    await Future.delayed(const Duration(milliseconds: 1000));

    onArrival?.call();
  }

  double _calculateDistance(ll.LatLng a, ll.LatLng b) {
    const ll.Distance distance = ll.Distance();
    return distance.as(ll.LengthUnit.Meter, a, b);
  }
}
