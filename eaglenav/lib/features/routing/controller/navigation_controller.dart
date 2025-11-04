import 'dart:async';
import 'package:latlong2/latlong.dart' as ll;
import '../services/valhalla_service.dart';
import '../services/speech.dart';
import '../services/haptics.dart';

class NavigationController {
  final Speech _speech = Speech();
  ValhallaRoute? _currentRoute;
  int _currentStepIndex = 0;
  final double _triggerDistanceMeters = 30.0; // Announce 30m before turn
  final Set<int> _announcedSteps = {};

  StreamSubscription? _locationSubscription;

  /// Start navigation with a route
  void startNavigation(ValhallaRoute route) {
    _currentRoute = route;
    _currentStepIndex = 0;
    _announcedSteps.clear();

    // Announce first instruction
    if (route.steps.isNotEmpty) {
      _announceStep(route.steps[0]);
    }
  }

  /// Call this when user location updates
  void updateLocation(ll.LatLng currentLocation) {
    if (_currentRoute == null) return;

    final steps = _currentRoute!.steps;
    if (_currentStepIndex >= steps.length) {
      // Navigation complete
      return;
    }

    // Check upcoming steps
    for (int i = _currentStepIndex; i < steps.length; i++) {
      final step = steps[i];
      final distance = _calculateDistance(currentLocation, step.location);

      // If we're close to this step and haven't announced it yet
      if (distance <= _triggerDistanceMeters && !_announcedSteps.contains(i)) {
        _announceStep(step);
        _announcedSteps.add(i);
        _currentStepIndex = i;
        break;
      }

      // If we passed this step, move to next
      if (distance < 10 && i == _currentStepIndex) {
        _currentStepIndex = i + 1;
      }
    }
  }

  /// Announce a navigation step with TTS and haptics
  Future<void> _announceStep(NavigationStep step) async {
    print('📢 Announcing: ${step.instruction}');

    // Trigger haptics first (instant feedback)
    final hapticKind = step.getHapticKind();
    final hapticEvent = Haptics.fromKind(hapticKind);
    await Haptics.fire(hapticEvent);

    // Then speak the instruction
    await _speech.announceDirection(step.getTTSInstruction());
  }

  /// Calculate distance between two points in meters
  double _calculateDistance(ll.LatLng point1, ll.LatLng point2) {
    const ll.Distance distance = ll.Distance();
    return distance.as(ll.LengthUnit.Meter, point1, point2);
  }

  /// Get current step instruction for UI display
  String? getCurrentInstruction() {
    if (_currentRoute == null ||
        _currentStepIndex >= _currentRoute!.steps.length) {
      return null;
    }
    return _currentRoute!.steps[_currentStepIndex].instruction;
  }

  /// Get distance to next turn
  double? getDistanceToNextTurn(ll.LatLng currentLocation) {
    if (_currentRoute == null ||
        _currentStepIndex >= _currentRoute!.steps.length) {
      return null;
    }
    final nextStep = _currentRoute!.steps[_currentStepIndex];
    return _calculateDistance(currentLocation, nextStep.location);
  }

  /// Stop navigation
  void stopNavigation() {
    _currentRoute = null;
    _currentStepIndex = 0;
    _announcedSteps.clear();
    _locationSubscription?.cancel();
  }

  /// Check if navigation is active
  bool get isNavigating => _currentRoute != null;

  /// Get progress (0.0 to 1.0)
  double getProgress() {
    if (_currentRoute == null || _currentRoute!.steps.isEmpty) return 0.0;
    return _currentStepIndex / _currentRoute!.steps.length;
  }
}
