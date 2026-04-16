import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

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

class _CVisionObjectsScreenState extends State<CVisionObjectsScreen>
    with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  String _lastSentence = '';
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  MethodChannel? _arcoreChannel;
  bool _hasError = false;
  String _errorMessage = '';
  bool _isReady = false;
  bool _cameraGranted = !Platform.isAndroid;

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _init(); }

  Future<void> _init() async {
    try {
      await _initTts();
      if (Platform.isAndroid) {
        final granted = await _ensureAndroidCameraPermission();
        if (!mounted) return;
        if (!granted) { setState(() { _hasError = true; _errorMessage = 'Camera permission required.'; _isReady = false; _cameraGranted = false; }); return; }
        _cameraGranted = true;
      }
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      debugPrint('CV init error: $e');
      if (mounted) setState(() { _hasError = true; _errorMessage = 'Failed to initialize: $e'; });
    }
  }

  Future<void> _initTts() async { await _tts.setLanguage('en-US'); await _tts.setSpeechRate(0.5); await _tts.setVolume(1.0); }

  Future<bool> _ensureAndroidCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted) return true;
    status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<void> _resumeArCore({String contextLabel = 'resume'}) async {
    final c = _arcoreChannel; if (c == null) return;
    try { await c.invokeMethod('resume'); } catch (e) { debugPrint('ARCore $contextLabel: $e'); }
  }
  Future<void> _pauseArCore({String contextLabel = 'pause'}) async {
    final c = _arcoreChannel; if (c == null) return;
    try { await c.invokeMethod('pause'); } catch (e) { debugPrint('ARCore $contextLabel: $e'); }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasError) { setState(() { _hasError = false; _errorMessage = ''; _isReady = false; }); _init(); return; }
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.resumed) _resumeArCore(contextLabel: 'app resume');
    else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached) _pauseArCore(contextLabel: 'app pause');
  }

  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); _tts.stop(); _pauseArCore(contextLabel: 'dispose'); super.dispose(); }

  bool _cooldownOk(DateTime now, {int seconds = 2}) => now.difference(_lastSpoken).inSeconds >= seconds;

  Future<void> _speak(String sentence) async {
    final now = DateTime.now();
    if (!_cooldownOk(now)) return;
    if (sentence == _lastSentence) return;
    setState(() { _lastSentence = sentence; _lastSpoken = now; });
    try { await _tts.stop(); await _tts.speak(sentence); } catch (e) { debugPrint('TTS: $e'); }
  }

  bool _isPillarLike(String name) { final n = name.toLowerCase(); return n.contains('pillar') || n.contains('column') || n.contains('pole') || n.contains('post') || n.contains('bollard'); }

  Future<void> _announceDetections(Iterable<String> names) async {
    final now = DateTime.now(); if (!_cooldownOk(now)) return;
    final others = <String>{}; var hasPillar = false;
    for (final rawName in names) { final name = rawName.trim(); if (name.isEmpty) continue; if (_isPillarLike(name)) hasPillar = true; else others.add(name); }
    if (!hasPillar && others.isEmpty) return;
    final parts = <String>[]; if (hasPillar) parts.add('pillar'); if (others.isNotEmpty) parts.addAll(others.take(3));
    await _speak('I see ${parts.join(', ')}');
  }

  Future<void> _handleResults(List<YOLOResult> results) async {
    if (results.isEmpty) return;
    await _announceDetections(results.map((r) => r.className).whereType<String>());
  }

  void _onArCorePlatformViewCreated(int viewId) {
    final channel = MethodChannel('arcore_yolo_view_$viewId');
    _arcoreChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'onDetections') return;
      final arguments = call.arguments;
      final payload = arguments is List ? List<dynamic>.from(arguments) : const <dynamic>[];
      await _handleArcoreDetections(payload);
    });
    _resumeArCore(contextLabel: 'view created');
  }

  Future<void> _handleArcoreDetections(List<dynamic> payload) async {
    if (payload.isEmpty) return;
    final names = <String>[];
    for (final item in payload) { if (item is! Map) continue; final cn = item['class']; if (cn is String && cn.isNotEmpty) names.add(cn); }
    if (names.isEmpty) return;
    await _announceDetections(names);
  }

  void _retry() { setState(() { _hasError = false; _errorMessage = ''; _isReady = false; }); _init(); }

  @override
  Widget build(BuildContext context) {
    final String modelPath = Platform.isAndroid ? 'yolo11n.tflite' : 'yolo11n';
    return Scaffold(
      appBar: AppBar(title: const Text('Computer Vision (Objects + Distance)'), backgroundColor: const Color.fromARGB(255, 161, 133, 40), actions: [
        IconButton(tooltip: 'Segmentation', icon: const Icon(Icons.texture), onPressed: () async {
          await _tts.stop();
          if (Platform.isAndroid) await _pauseArCore(contextLabel: 'before seg');
          if (!mounted) return;
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const CVisionSegmentationScreen()));
          if (!mounted || !Platform.isAndroid) return;
          _resumeArCore(contextLabel: 'after seg');
        }),
      ]),
      body: _hasError
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red), const SizedBox(height: 16),
              Text('Camera failed to start', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8), Text(_errorMessage, textAlign: TextAlign.center),
              const SizedBox(height: 24), ElevatedButton.icon(onPressed: _retry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
            ])))
          : Stack(children: [
              if (_isReady) _ObjectCameraView(modelPath: modelPath, onResult: _handleResults, onAndroidPlatformViewCreated: _onArCorePlatformViewCreated, onError: (e) { if (!mounted) return; setState(() { _hasError = true; _errorMessage = e; _isReady = false; }); })
              else const Center(child: CircularProgressIndicator()),
              Positioned(left: 16, right: 16, bottom: 32, child: _Hud(text: _lastSentence.isEmpty ? 'Point the camera at something…' : _lastSentence)),
            ]),
    );
  }
}

class _ObjectCameraView extends StatelessWidget {
  final String modelPath; final void Function(List<YOLOResult>) onResult; final ValueChanged<int> onAndroidPlatformViewCreated; final void Function(String) onError;
  const _ObjectCameraView({required this.modelPath, required this.onResult, required this.onAndroidPlatformViewCreated, required this.onError});
  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) return _AndroidArCoreYoloView(onPlatformViewCreated: onAndroidPlatformViewCreated);
    return _SafeYOLOView(modelPath: modelPath, task: YOLOTask.detect, onResult: onResult, onError: onError);
  }
}

class _AndroidArCoreYoloView extends StatelessWidget {
  final ValueChanged<int> onPlatformViewCreated;
  const _AndroidArCoreYoloView({required this.onPlatformViewCreated});
  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(key: const ValueKey('android_arcore_yolo_view'), viewType: 'arcore_yolo_view',
      surfaceFactory: (context, controller) => AndroidViewSurface(controller: controller as AndroidViewController, gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{}, hitTestBehavior: PlatformViewHitTestBehavior.opaque),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(id: params.id, viewType: 'arcore_yolo_view', layoutDirection: TextDirection.ltr, onFocus: () => params.onFocusChanged(true));
        controller.addOnPlatformViewCreatedListener((viewId) { params.onPlatformViewCreated(viewId); onPlatformViewCreated(viewId); });
        controller.create(); return controller;
      },
    );
  }
}

class _SafeYOLOView extends StatefulWidget {
  final String modelPath; final YOLOTask task; final void Function(List<YOLOResult>) onResult; final void Function(String) onError;
  const _SafeYOLOView({required this.modelPath, required this.task, required this.onResult, required this.onError});
  @override State<_SafeYOLOView> createState() => _SafeYOLOViewState();
}
class _SafeYOLOViewState extends State<_SafeYOLOView> {
  @override
  Widget build(BuildContext context) {
    return YOLOView(key: ValueKey('yolo_${widget.task.name}_view'), modelPath: widget.modelPath, task: widget.task, confidenceThreshold: 0.30, showOverlays: true, onResult: widget.onResult);
  }
}

// ─────────────────────────────────────────────────────────────────
// SEGMENTATION SCREEN
//
// Android: uses arcore_seg_view — native ARCore view that runs the
// seg TFLite model AND measures distance with depth. Same approach
// as the detection screen but with yolo11n-seg.tflite.
//
// iOS: uses YOLO plugin YOLOView (no distance).
// ─────────────────────────────────────────────────────────────────

class CVisionSegmentationScreen extends StatefulWidget {
  const CVisionSegmentationScreen({super.key});
  @override State<CVisionSegmentationScreen> createState() => _CVisionSegmentationScreenState();
}

class _CVisionSegmentationScreenState extends State<CVisionSegmentationScreen> with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  String _status = 'Segmentation active…';
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  MethodChannel? _arcoreSegChannel;
  bool _hasError = false;
  bool _isReady = false;
  bool _cameraGranted = !Platform.isAndroid;

  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _init(); }

  Future<void> _init() async {
    try {
      await _initTts();
      if (Platform.isAndroid) {
        final granted = await _ensureAndroidCameraPermission();
        if (!mounted) return;
        if (!granted) { setState(() { _hasError = true; _isReady = false; _cameraGranted = false; }); return; }
        _cameraGranted = true;
      }
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      debugPrint('Seg init error: $e');
      if (mounted) setState(() => _hasError = true);
    }
  }

  Future<void> _initTts() async { await _tts.setLanguage('en-US'); await _tts.setSpeechRate(0.5); await _tts.setVolume(1.0); }

  Future<bool> _ensureAndroidCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted) return true;
    status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<void> _resumeArCore({String contextLabel = 'resume'}) async {
    final c = _arcoreSegChannel; if (c == null) return;
    try { await c.invokeMethod('resume'); } catch (e) { debugPrint('ARCore seg $contextLabel: $e'); }
  }
  Future<void> _pauseArCore({String contextLabel = 'pause'}) async {
    final c = _arcoreSegChannel; if (c == null) return;
    try { await c.invokeMethod('pause'); } catch (e) { debugPrint('ARCore seg $contextLabel: $e'); }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasError) { setState(() { _hasError = false; _isReady = false; }); _init(); return; }
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.resumed) _resumeArCore(contextLabel: 'app resume');
    else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached) _pauseArCore(contextLabel: 'app pause');
  }

  @override void dispose() { WidgetsBinding.instance.removeObserver(this); _tts.stop(); _pauseArCore(contextLabel: 'dispose'); super.dispose(); }

  bool _cooldownOk(DateTime now, {int seconds = 2}) => now.difference(_lastSpoken).inSeconds >= seconds;

  Future<void> _speak(String sentence) async {
    final now = DateTime.now(); if (!_cooldownOk(now)) return;
    setState(() { _status = sentence; _lastSpoken = now; });
    try { await _tts.stop(); await _tts.speak(sentence); } catch (e) { debugPrint('TTS: $e'); }
  }

  void _onArCoreSegViewCreated(int viewId) {
    final channel = MethodChannel('arcore_seg_view_$viewId');
    _arcoreSegChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'onDetections') return;
      final arguments = call.arguments;
      final payload = arguments is List ? List<dynamic>.from(arguments) : const <dynamic>[];
      await _handleArcoreSegDetections(payload);
    });
    _resumeArCore(contextLabel: 'seg view created');
  }

  Future<void> _handleArcoreSegDetections(List<dynamic> payload) async {
    if (payload.isEmpty) return;
    final now = DateTime.now(); if (!_cooldownOk(now)) return;

    bool sawWall = false, sawStairs = false;
    String wallDist = '', stairsDist = '';

    for (final item in payload) {
      if (item is! Map) continue;
      final cn = (item['class'] as String?)?.toLowerCase() ?? '';
      if (cn.isEmpty) continue;
      final dt = item['distance_text'] as String?;
      if (cn.contains('wall')) { sawWall = true; if (dt != null && wallDist.isEmpty) wallDist = ' $dt away'; }
      if (cn.contains('stair') || cn.contains('step')) { sawStairs = true; if (dt != null && stairsDist.isEmpty) stairsDist = ' $dt away'; }
    }

    if (!sawWall && !sawStairs) return;
    if (sawStairs && sawWall) await _speak('Stairs$stairsDist and wall$wallDist detected');
    else if (sawStairs) await _speak('Stairs detected$stairsDist');
    else await _speak('Wall detected$wallDist');
  }

  Future<void> _handleSegResultsIOS(List<YOLOResult> results) async {
    if (results.isEmpty) return;
    final now = DateTime.now(); if (!_cooldownOk(now)) return;
    bool sawWall = false, sawStairs = false;
    for (final r in results) { final n = r.className?.toLowerCase() ?? ''; if (n.contains('wall')) sawWall = true; if (n.contains('stair') || n.contains('step')) sawStairs = true; }
    if (!sawWall && !sawStairs) return;
    if (sawStairs && sawWall) await _speak('Stairs and wall detected');
    else if (sawStairs) await _speak('Stairs detected');
    else await _speak('Wall detected');
  }

  @override
  Widget build(BuildContext context) {
    final String modelPath = Platform.isAndroid ? 'yolo11n-seg.tflite' : 'yolo11n-seg';
    return Scaffold(
      appBar: AppBar(title: const Text('Computer Vision (Segmentation)'), backgroundColor: const Color.fromARGB(255, 161, 133, 40)),
      body: _hasError
          ? Center(child: ElevatedButton.icon(onPressed: () { setState(() { _hasError = false; _isReady = false; }); _init(); }, icon: const Icon(Icons.refresh), label: const Text('Retry')))
          : Stack(children: [
              if (_isReady)
                Platform.isAndroid
                    ? _AndroidArCoreSegView(onPlatformViewCreated: _onArCoreSegViewCreated)
                    : YOLOView(key: const ValueKey('yolo_segment_view'), modelPath: modelPath, task: YOLOTask.segment, confidenceThreshold: 0.30, showOverlays: true, onResult: _handleSegResultsIOS)
              else const Center(child: CircularProgressIndicator()),
              Positioned(left: 16, right: 16, bottom: 32, child: _Hud(text: _status)),
            ]),
    );
  }
}

class _AndroidArCoreSegView extends StatelessWidget {
  final ValueChanged<int> onPlatformViewCreated;
  const _AndroidArCoreSegView({required this.onPlatformViewCreated});
  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(key: const ValueKey('android_arcore_seg_view'), viewType: 'arcore_seg_view',
      surfaceFactory: (context, controller) => AndroidViewSurface(controller: controller as AndroidViewController, gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{}, hitTestBehavior: PlatformViewHitTestBehavior.opaque),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(id: params.id, viewType: 'arcore_seg_view', layoutDirection: TextDirection.ltr, onFocus: () => params.onFocusChanged(true));
        controller.addOnPlatformViewCreatedListener((viewId) { params.onPlatformViewCreated(viewId); onPlatformViewCreated(viewId); });
        controller.create(); return controller;
      },
    );
  }
}

class _Hud extends StatelessWidget {
  final String text;
  const _Hud({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: const TextStyle(fontSize: 16, color: Colors.white), textAlign: TextAlign.center));
  }
}
