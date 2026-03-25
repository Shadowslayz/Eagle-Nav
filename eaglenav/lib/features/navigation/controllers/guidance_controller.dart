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

  /// Called whenever the step index advances. The screen wires this to
  /// NavigationVoiceController.announceStep() so TTS fires on each new step.
  VoidCallback? onStepAdvanced;
  VoidCallback? onArrival;

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

    // ---  GLOBAL ARRIVAL CHECK ---
    // If the user is within a safe threshold of the total destination,
    // trigger arrival immediately.
    final finalStep = steps.last;
    final distanceToDestination = _calculateDistance(
      position,
      finalStep.location,
    );

    if (distanceToDestination <= 15.0) {
      _handleArrival(finalStep);
      return;
    }

    // Look ahead a bounded window to avoid over-advancing on a long straight
    // segment that passes close to a future turn point.
    final lookAheadLimit = (_currentStepIndex + 3).clamp(0, steps.length);

    for (int i = _currentStepIndex; i < lookAheadLimit; i++) {
      final step = steps[i];
      final distance = _calculateDistance(position, step.endLocation);
      final isLastStep = i == steps.length - 1;
      final distanceToStepEnd = _calculateDistance(position, step.endLocation);

      // If we are on the last or second-to-last step and close enough...
      if (i >= steps.length - 2 && distanceToStepEnd <= stepCompleteMeters) {
        _handleArrival(steps.last);
        return;
      }

      if (distanceToStepEnd < stepCompleteMeters && i == _currentStepIndex) {
        _advanceStep(i + 1);
        break;
      }

      // ── Arrival detection ──────────────────────────────
      if (isLastStep && distance <= stepCompleteMeters) {
        _handleArrival(step);
        return;
      }

      // ── Step completion ────────────────────────────────
      // Advance once the user has clearly passed the step location.
      // Only advance the current index to avoid skipping multiple steps.
      if (distance < stepCompleteMeters && i == _currentStepIndex) {
        _advanceStep(i + 1);
        break;
      }
    }
  }

  // ── Internals ─────────────────────────────────────────────

  void _advanceStep(int newIndex) {
    _currentStepIndex = newIndex;
    notifyListeners();
    onStepAdvanced?.call();
  }

  Future<void> _handleArrival(NavigationStep arrivalStep) async {
    if (_hasArrived) return; // prevent repeat calls on successive GPS ticks
    _hasArrived = true;
    notifyListeners();
    debugPrint(' ${arrivalStep.instruction}');
    final hapticEvent = Haptics.fromKind(arrivalStep.getHapticKind());
    await Haptics.fire(hapticEvent);
    onStepAdvanced
        ?.call(); // ← triggers the screen → voice controller → cases 4/5/6
    onArrival?.call(); // tells the screen to stop navigation
  }

  double _calculateDistance(ll.LatLng a, ll.LatLng b) {
    const ll.Distance distance = ll.Distance();
    return distance.as(ll.LengthUnit.Meter, a, b);
  }
}
