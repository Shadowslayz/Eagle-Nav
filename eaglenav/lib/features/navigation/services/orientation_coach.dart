import 'dart:ui';
import 'package:eaglenav/features/navigation/utils/bearing_utils.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'compass_service.dart';
import '../services/tts_manager.dart';

/// ─── OrientationCoach ────────────────────────────────────────────────────────
///
/// Guides the user to face a target bearing using the compass.
/// Used at the start of navigation and after each reroute.
///
/// Key fix: stores the listener reference so it can be properly removed
/// before adding a new one — prevents listener accumulation across steps.
/// ─────────────────────────────────────────────────────────────────────────────

class OrientationCoach {
  final CompassService _compass;
  //final FlutterTts _tts;
  TtsManager _ttsManager;
  final bool Function() isBusy;

  bool _active = false;
  double _targetBearing = 0;
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);

  static const int _bufferSize = 15;
  final List<double> _angleBuffer = [];

  static const Duration _speakInterval = Duration(seconds: 15);
  static const double _acceptableError = 10.0;
  bool _isCoachSpeaking = false;

  // ── Store listener reference so we can remove it cleanly ──
  void Function()? _activeListener;

  OrientationCoach(this._compass, this._ttsManager, {required this.isBusy});

  void startGuiding({
    required double targetBearing,
    required VoidCallback onAligned,
    String? streetName,
  }) {
    // ── Remove any previous listener before starting a new one ──
    _stopListening();

    _active = true;
    _targetBearing = targetBearing;
    _angleBuffer.clear();
    //_lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);

    // Store reference so we can remove it later
    _activeListener = () async {
      if (!_active) return;

      final relAngle = BearingUtils.relativeAngle(
        _compass.currentHeading,
        _targetBearing,
      );
      final absAngle = relAngle.abs();

      // rolling average — smooths compass jitter
      _angleBuffer.add(absAngle);
      if (_angleBuffer.length > _bufferSize) _angleBuffer.removeAt(0);
      if (_angleBuffer.length < _bufferSize) return;

      final avgAngle =
          _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

      // ── Aligned — stop coaching ──────────────────────────
      if (avgAngle < _acceptableError) {
        _stopListening();
        await _ttsManager.stop();
        await _ttsManager.speak(
          streetName != null && streetName.isNotEmpty
              ? 'Locked in. Align your body with the phone and walk forward.'
              : 'Locked in. Align your body with the phone and walk forward.',
          TtsPriority.high,
        );
        onAligned();
        return;
      }

      // ── Throttle speaking ────────────────────────────────
      final now = DateTime.now();
      if (now.difference(_lastSpoken) < _speakInterval) return;
      if (isBusy()) return;
      if (_isCoachSpeaking) return;

      _lastSpoken = now;
      _isCoachSpeaking = true;

      final dir = relAngle > 0 ? 'right' : 'left';

      String message;

      if (avgAngle > 150) {
        // 150 to 180 degrees is genuinely behind the user
        message = 'Turn all the way around to the $dir.';
      } else if (avgAngle > 75) {
        // 75 to 150 captures a standard 90-degree right angle turn
        message = 'Turn $dir, about a quarter turn.';
      } else if (avgAngle > 30) {
        // 30 to 75 is a standard diagonal/shallow turn
        message = 'Turn $dir.';
      } else {
        // 10 to 30 degrees off target
        message = 'Almost there. Slightly to the $dir.';
      }

      await _ttsManager.stop();
      await _ttsManager.speak(message, TtsPriority.normal);

      // sets the cooldown timer after the speech ends.
      // This guarantees exactly x seconds of pure silence before the next prompt.
      _lastSpoken = DateTime.now();
      _isCoachSpeaking = false;
    };

    _compass.headingNotifier.addListener(_activeListener!);
  }

  void stop() {
    _stopListening();
  }

  void _stopListening() {
    _active = false;
    _isCoachSpeaking = false;
    _angleBuffer.clear();
    if (_activeListener != null) {
      _compass.headingNotifier.removeListener(_activeListener!);
      _activeListener = null;
    }
  }
}
