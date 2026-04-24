import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

/// ✅ main.dart calls CVisionScreen(), so keep this wrapper.
class cv_screen extends StatelessWidget {
  const cv_screen({super.key});

  @override
  Widget build(BuildContext context) => const CVisionObjectsScreen();
}

class CVisionObjectsScreen extends StatefulWidget {
  const CVisionObjectsScreen({super.key});

  @override
  State<CVisionObjectsScreen> createState() => _CVisionObjectsScreenState();
}

class _CVisionObjectsScreenState extends State<CVisionObjectsScreen> {
  final FlutterTts _tts = FlutterTts();

  String _lastSentence = '';
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  bool _checkingCameraPermission = true;
  PermissionStatus _cameraPermissionStatus = PermissionStatus.denied;

  @override
  void initState() {
    super.initState();
    _initTts();
    _requestCameraPermission();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    // optional but helps avoid overlap on some devices:
    // await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _cameraPermissionStatus = status;
      _checkingCameraPermission = false;
    });
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  bool _cooldownOk(DateTime now, {int seconds = 2}) =>
      now.difference(_lastSpoken).inSeconds >= seconds;

  Future<void> _speak(String sentence) async {
    final now = DateTime.now();
    if (!_cooldownOk(now)) return;
    if (sentence == _lastSentence) return;

    setState(() {
      _lastSentence = sentence;
      _lastSpoken = now;
    });

    await _tts.stop();
    await _tts.speak(sentence);
  }

  bool _isPillarLike(String name) {
    final n = name.toLowerCase();
    return n.contains('pillar') ||
        n.contains('column') ||
        n.contains('pole') ||
        n.contains('post') ||
        n.contains('bollard');
  }

  Future<void> _handleResults(List<YOLOResult> results) async {
    if (results.isEmpty) return;

    final now = DateTime.now();
    if (!_cooldownOk(now)) return;

    final others = <String>{};
    bool hasPillar = false;

    for (final r in results) {
      final name = r.className;
      if (name.isEmpty) continue;

      if (_isPillarLike(name)) {
        hasPillar = true;
      } else {
        others.add(name);
      }
    }

    if (!hasPillar && others.isEmpty) return;

    final parts = <String>[];
    if (hasPillar) parts.add('pillar');
    if (others.isNotEmpty) parts.addAll(others.take(3));

    await _speak('I see ${parts.join(', ')}');
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingCameraPermission) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_cameraPermissionStatus.isGranted) {
      final permanentlyDenied =
          _cameraPermissionStatus.isPermanentlyDenied ||
          _cameraPermissionStatus.isRestricted;
      return Scaffold(
        appBar: AppBar(title: const Text('Computer Vision')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.camera_alt_outlined, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Camera access is required for live object detection.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: permanentlyDenied
                      ? openAppSettings
                      : _requestCameraPermission,
                  child: Text(
                    permanentlyDenied ? 'Open Settings' : 'Allow Camera',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ✅ same strategy as your “works” version
    final String modelPath = Platform.isAndroid ? 'yolo11n.tflite' : 'yolo11n';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Computer Vision'),
        actions: [
          Semantics(
            label: 'Switch to segmentation view',
            button: true,
            child: IconButton(
              tooltip: 'Segmentation',
              icon: const Icon(Icons.texture, semanticLabel: 'Segmentation'),
              onPressed: () async {
                await _tts.stop();
                if (!context.mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CVisionSegmentationScreen(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          SizedBox.expand(
            child: YOLOView(
              key: const ValueKey('yolo_detect_view'),
              modelPath: modelPath,
              task: YOLOTask.detect,
              confidenceThreshold: 0.30,
              showOverlays: true,
              onResult: _handleResults,
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: _Hud(
              text: _lastSentence.isEmpty
                  ? 'Point the camera at something…'
                  : _lastSentence,
            ),
          ),
        ],
      ),
    );
  }
}

class CVisionSegmentationScreen extends StatefulWidget {
  const CVisionSegmentationScreen({super.key});

  @override
  State<CVisionSegmentationScreen> createState() =>
      _CVisionSegmentationScreenState();
}

class _CVisionSegmentationScreenState extends State<CVisionSegmentationScreen> {
  final FlutterTts _tts = FlutterTts();

  String _status = 'Segmentation active…';
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  bool _checkingCameraPermission = true;
  PermissionStatus _cameraPermissionStatus = PermissionStatus.denied;

  @override
  void initState() {
    super.initState();
    _initTts();
    _requestCameraPermission();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    // optional:
    // await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _cameraPermissionStatus = status;
      _checkingCameraPermission = false;
    });
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  bool _cooldownOk(DateTime now, {int seconds = 2}) =>
      now.difference(_lastSpoken).inSeconds >= seconds;

  Future<void> _speak(String sentence) async {
    final now = DateTime.now();
    if (!_cooldownOk(now)) return;

    setState(() {
      _status = sentence;
      _lastSpoken = now;
    });

    await _tts.stop();
    await _tts.speak(sentence);
  }

  Future<void> _handleSegResults(List<YOLOResult> results) async {
    if (results.isEmpty) return;

    final now = DateTime.now();
    if (!_cooldownOk(now)) return;

    bool sawWall = false;
    bool sawStairs = false;

    for (final r in results) {
      final name = r.className.toLowerCase();
      if (name.isEmpty) continue;

      if (name.contains('wall')) sawWall = true;
      if (name.contains('stair') || name.contains('step')) sawStairs = true;
    }

    if (!sawWall && !sawStairs) return;

    if (sawStairs && sawWall) {
      await _speak('Stairs and wall detected');
    } else if (sawStairs) {
      await _speak('Stairs detected');
    } else {
      await _speak('Wall detected');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingCameraPermission) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_cameraPermissionStatus.isGranted) {
      final permanentlyDenied =
          _cameraPermissionStatus.isPermanentlyDenied ||
          _cameraPermissionStatus.isRestricted;
      return Scaffold(
        appBar: AppBar(title: const Text('Segmentation')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.camera_alt_outlined, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Camera access is required for segmentation.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: permanentlyDenied
                      ? openAppSettings
                      : _requestCameraPermission,
                  child: Text(
                    permanentlyDenied ? 'Open Settings' : 'Allow Camera',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ✅ same strategy as your “works” version
    final String modelPath = Platform.isAndroid
        ? 'yolo11n-seg.tflite'
        : 'yolo11n-seg';

    return Scaffold(
      appBar: AppBar(title: const Text('Segmentation')),
      body: Stack(
        children: [
          YOLOView(
            key: const ValueKey('yolo_segment_view'),
            modelPath: modelPath,
            task: YOLOTask.segment,
            confidenceThreshold: 0.30,
            showOverlays: true,
            onResult: _handleSegResults,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: _Hud(text: _status),
          ),
        ],
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  final String text;
  const _Hud({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, color: Colors.white),
        textAlign: TextAlign.center,
      ),
    );
  }
}
