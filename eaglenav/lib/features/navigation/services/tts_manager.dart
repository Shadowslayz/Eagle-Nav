import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  TTS PRIORITY LEVELS
//  Higher priority interrupts lower priority speech.
//    high   → step announcements, reroute instructions, on-demand heading
//    normal → orientation coach guidance
//    low    → distance countdowns, drift warnings
// ─────────────────────────────────────────────────────────────────────────────
enum TtsPriority { low, normal, high }

// ─────────────────────────────────────────────────────────────────────────────
//  TTS MANAGER
//  Single owner of FlutterTts. Nothing else calls FlutterTts directly.
//
//  Priority rules:
//    - Lower priority → skipped if something is already speaking
//    - Equal or higher priority → interrupts current speech
//
//  Fallback timer ensures _isSpeaking never gets permanently stuck
//  on iOS where the completion handler can silently fail.
// ─────────────────────────────────────────────────────────────────────────────
class TtsManager {
  final FlutterTts _tts = FlutterTts();

  TtsPriority _currentPriority = TtsPriority.low;
  bool _isSpeaking = false;
  Timer? _fallbackTimer;

  Future<void> initialize() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    // Play through iOS silent switch
    await _tts.setSharedInstance(true);
    await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
      IosTextToSpeechAudioCategoryOptions.allowBluetooth,
      IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
      IosTextToSpeechAudioCategoryOptions.mixWithOthers,
    ], IosTextToSpeechAudioMode.defaultMode);

    _tts.setCompletionHandler(_onDone);
    _tts.setCancelHandler(_onDone);
    _tts.setErrorHandler((_) => _onDone());
  }

  void _onDone() {
    _isSpeaking = false;
    _currentPriority = TtsPriority.low;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }

  /// Speak [text] at [priority].
  /// Lower priority is skipped if already speaking.
  /// Equal or higher priority interrupts current speech.
  Future<void> speak(String text, TtsPriority priority) async {
    if (text.trim().isEmpty) return;

    // Skip if lower priority than what's currently playing
    if (_isSpeaking && priority.index < _currentPriority.index) return;

    // Interrupt if equal or higher priority
    if (_isSpeaking) {
      _fallbackTimer?.cancel();
      await _tts.stop();
      _isSpeaking = false;
    }

    _isSpeaking = true;
    _currentPriority = priority;

    await _tts.speak(text);

    // Fallback timer — unlocks _isSpeaking if completion handler doesn't fire
    final wordCount = text.split(' ').length;
    final estimatedMs = ((wordCount / 130) * 60 * 1000 / 0.45).round() + 1000;
    _fallbackTimer = Timer(Duration(milliseconds: estimatedMs), _onDone);
  }

  Future<void> stop() async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    await _tts.stop();
    _isSpeaking = false;
    _currentPriority = TtsPriority.low;
  }

  /// True only while a high-priority instruction is speaking.
  bool get isBusy => _isSpeaking && _currentPriority == TtsPriority.high;

  Future<void> dispose() => stop();
}
