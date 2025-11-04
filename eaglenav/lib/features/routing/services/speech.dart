import 'package:flutter/semantics.dart';
import 'package:flutter_tts/flutter_tts.dart';

class Speech {
  final FlutterTts _flutterTts = FlutterTts();

  Future<void> announceDirection(String text) async {
    try {
      await _flutterTts.stop();
      await _flutterTts.setLanguage("en-US");
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.speak(text);
      SemanticsService.announce(text, TextDirection.ltr);
    } catch (e) {
      print("Error announcing direction: $e");
    }
  }

  Future<void> sayInfo(String text) async {
    try {
      await _flutterTts.stop();
      await _flutterTts.setLanguage("en-US");
      await _flutterTts.speak(text);
      SemanticsService.announce(text, TextDirection.ltr);
    } catch (e) {
      print("Error speaking info: $e");
    }
  }
}
