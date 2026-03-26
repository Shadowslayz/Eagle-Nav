import 'package:flutter_tts/flutter_tts.dart';

final FlutterTts flutterTts = FlutterTts();
bool _ttsInitialized = false;

Future<void> initTts() async {
  if (_ttsInitialized) return;

  await flutterTts.setLanguage("en-US");
  await flutterTts.setPitch(1.0);

  _ttsInitialized = true;
}