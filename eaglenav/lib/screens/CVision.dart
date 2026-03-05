import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class CVisionScreen extends StatefulWidget {
  const CVisionScreen({super.key});
  @override
  State<CVisionScreen> createState() => _CVisionScreenState();
}

class _CVisionScreenState extends State<CVisionScreen> {
  final FlutterTts _tts = FlutterTts();
  String _lastSentence = '';
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  bool _useDoorModel = false;

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _handleResults(List<YOLOResult> results) async {
    if (results.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastSpoken).inSeconds < 2) return;
    final names = <String>{};
    for (final r in results) {
      if (r.className != null && r.className!.isNotEmpty) {
        names.add(r.className!);
      }
    }

    if (names.isEmpty) return;
    final sentence = 'I see ${names.join(', ')}';
    if (sentence == _lastSentence) return;
    setState(() {
      _lastSentence = sentence;
      _lastSpoken = now;
    });
    await _tts.stop();
    await _tts.speak(sentence);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Computer Vision'),
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                _useDoorModel = !_useDoorModel;
                _lastSentence = '';
              });
            },
            icon: Icon(
              _useDoorModel ? Icons.door_front_door : Icons.remove_red_eye,
              color: Colors.white,
            ),
            label: Text(
              _useDoorModel ? 'Doors' : 'General',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          YOLOView(
            key: ValueKey(_useDoorModel ? 'doors' : 'general'),
            modelPath: _useDoorModel ? 'doors' : 'yolo11n',
            task: YOLOTask.detect,
            confidenceThreshold: _useDoorModel ? 0.5 : 0.3,
            onResult: _handleResults,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _lastSentence.isEmpty
                    ? (_useDoorModel
                        ? 'Looking for doors…'
                        : 'Point the camera at something…')
                    : _lastSentence,
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}