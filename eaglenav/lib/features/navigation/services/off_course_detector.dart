import 'package:eaglenav/features/navigation/services/tts_manager.dart';
import '../utils/bearing_utils.dart';

/// ─── OffCourseDetector ───────────────────────────────────────────────────────
///
/// Detects when the user has physically drifted off the route polyline
/// and announces the distance in steps. No compass involvement — compass
/// is only used by OrientationCoach during turn reorientation.
///
/// Thresholds sit below RoutingController.deviationThresholdMeters (30m):
///   0–10m   → silent, user is on path
///   10–20m  → "about X steps off the path"
///   20–30m  → "X steps off the path, rerouting soon"
///   30m+    → RoutingController triggers reroute → announceStep → OrientationCoach
/// ─────────────────────────────────────────────────────────────────────────────

class OffCourseDetector {
  //final FlutterTts _tts;
  final TtsManager _tts;
  final bool Function() isBusy;

  bool _active = false;
  DateTime _lastWarning = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _warnInterval = Duration(seconds: 10);
  static const double _nearThreshold = 10.0; // just off path
  static const double _farThreshold = 20.0; // clearly off, reroute incoming

  OffCourseDetector(this._tts, {required this.isBusy});

  void activate() => _active = true;

  void deactivate() => _active = false;

  Future<void> onDeviation(double deviationMeters) async {
    if (!_active) return;
    if (deviationMeters < _nearThreshold) return; // on path, silent
    if (isBusy()) return; // instruction still speaking

    final now = DateTime.now();
    if (now.difference(_lastWarning) < _warnInterval) return;
    _lastWarning = now;

    final steps = BearingUtils.metersToSteps(deviationMeters);

    String message;
    if (deviationMeters < _farThreshold) {
      message = 'You are about $steps steps off the path.';
    } else {
      message = 'You are $steps steps off the path. Rerouting now.';
    }

    await _tts.stop();
    await _tts.speak(message, TtsPriority.high);
  }
}
