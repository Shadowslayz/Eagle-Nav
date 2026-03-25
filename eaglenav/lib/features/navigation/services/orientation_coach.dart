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

  static const Duration _speakInterval = Duration(seconds: 5);
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
    _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);

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
              ? 'Locked in. Align your body with the phone and walk forward on $streetName.'
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
      if (avgAngle > 120) {
        message = 'Turn all the way around to the $dir.';
      } else if (avgAngle > 60) {
        message = 'Turn $dir, about a quarter turn.';
      } else if (avgAngle > 30) {
        message = 'Turn $dir.';
      } else {
        message = 'Almost there. Slightly to the $dir.';
      }

      await _ttsManager.stop();
      await _ttsManager.speak(message, TtsPriority.normal);
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
