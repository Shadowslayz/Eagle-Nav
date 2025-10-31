import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart';

enum HapticsEvent { start, turnLeft, turnRight, continueAhead, arrive, hazard }

class Haptics {
  static DateTime? _last;
  static Future<void> fire(HapticsEvent e) async {
    if (_last != null && DateTime.now().difference(_last!).inMilliseconds < 600)
      return;
    _last = DateTime.now();
    final has = await Vibration.hasVibrator();
    if (!has) return HapticFeedback.selectionClick();
    switch (e) {
      case HapticsEvent.start:
        await Vibration.vibrate(duration: 70);
        break; // short
      case HapticsEvent.turnLeft:
        await Vibration.vibrate(pattern: [0, 60, 60, 60]);
        break; // double
      case HapticsEvent.turnRight:
        await Vibration.vibrate(pattern: [0, 60, 120, 60]);
        break; // spaced double
      case HapticsEvent.continueAhead:
        await Vibration.vibrate(duration: 40);
        break; // tap
      case HapticsEvent.arrive:
        await Vibration.vibrate(duration: 250);
        break; // long
      case HapticsEvent.hazard:
        await Vibration.vibrate(pattern: [0, 80, 80, 80, 80, 80]);
        break; // triple+
    }
  }

  // Map route "kind" -> haptics
  static HapticsEvent fromKind(String kind) {
    switch (kind.toUpperCase()) {
      case 'START':
        return HapticsEvent.start;
      case 'TURN_LEFT':
        return HapticsEvent.turnLeft;
      case 'TURN_RIGHT':
        return HapticsEvent.turnRight;
      case 'ARRIVE':
        return HapticsEvent.arrive;
      case 'HAZARD':
        return HapticsEvent.hazard;
      default:
        return HapticsEvent.continueAhead;
    }
  }
}
