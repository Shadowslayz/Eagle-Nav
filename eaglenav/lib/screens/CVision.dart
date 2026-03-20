import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class CVisionScreen extends StatefulWidget {
  const CVisionScreen({super.key});

  @override
  State<CVisionScreen> createState() => _CVisionScreenState();
}

class _CVisionScreenState extends State<CVisionScreen>
    with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();

  String _lastSentence = '';
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);

  MethodChannel? _arcoreChannel;

  bool _cameraGranted = false;
  bool _checkingPermission = true;
  bool _openingSettings = false;
  String? _permissionMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _checkAndRequestCameraPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tts.stop();
    _arcoreChannel?.invokeMethod('pause').catchError((_) {});
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatus();

      if (Platform.isAndroid) {
        _arcoreChannel?.invokeMethod('resume').catchError((e) {
          debugPrint('ARCore resume error on app resume: $e');
        });
      }
    } else if (state == AppLifecycleState.paused) {
      if (Platform.isAndroid) {
        _arcoreChannel?.invokeMethod('pause').catchError((e) {
          debugPrint('ARCore pause error on app pause: $e');
        });
      }
    }
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
  }

  Future<void> _checkAndRequestCameraPermission() async {
    setState(() {
      _checkingPermission = true;
      _permissionMessage = null;
    });

    try {
      PermissionStatus status = await Permission.camera.status;

      if (status.isDenied) {
        status = await Permission.camera.request();
      }

      if (!mounted) return;

      setState(() {
        _cameraGranted = status.isGranted;
        _checkingPermission = false;

        if (status.isGranted) {
          _permissionMessage = null;
        } else if (status.isPermanentlyDenied || status.isRestricted) {
          _permissionMessage =
              'Camera access is disabled for Eagle Nav. Enable it in Settings.';
        } else {
          _permissionMessage =
              'Camera permission is required to use Computer Vision.';
        }
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _cameraGranted = false;
        _checkingPermission = false;
        _permissionMessage = 'Failed to request camera permission: $e';
      });
    }
  }

  Future<void> _refreshPermissionStatus() async {
    try {
      final status = await Permission.camera.status;
      if (!mounted) return;

      setState(() {
        _cameraGranted = status.isGranted;
        if (status.isGranted) {
          _permissionMessage = null;
        } else if (status.isPermanentlyDenied || status.isRestricted) {
          _permissionMessage =
              'Camera access is disabled for Eagle Nav. Enable it in Settings.';
        } else {
          _permissionMessage =
              'Camera permission is required to use Computer Vision.';
        }
      });
    } catch (e) {
      debugPrint('Permission refresh error: $e');
    }
  }

  Future<void> _openSettings() async {
    setState(() {
      _openingSettings = true;
    });

    try {
      await openAppSettings();
    } finally {
      if (mounted) {
        setState(() {
          _openingSettings = false;
        });
      }
    }
  }

  Future<void> _handleResults(List<YOLOResult> results) async {
    if (results.isEmpty) return;

    final now = DateTime.now();
    if (now.difference(_lastSpoken).inSeconds < 2) return;

    final names = <String>{};
    for (final r in results) {
      if (r.className.isNotEmpty) {
        names.add(r.className);
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

  void _onArCorePlatformViewCreated(int viewId) {
    final channel = MethodChannel('arcore_yolo_view_$viewId');
    _arcoreChannel = channel;

    channel.setMethodCallHandler((call) async {
      if (call.method == 'onDetections') {
        final List<dynamic> payload = call.arguments ?? [];
        await _handleArcoreDetections(payload);
      }
    });

    channel.invokeMethod('resume').catchError((e) {
      debugPrint('ARCore resume error: $e');
    });
  }

  Future<void> _handleArcoreDetections(List<dynamic> payload) async {
    if (payload.isEmpty) return;

    final now = DateTime.now();
    if (now.difference(_lastSpoken).inSeconds < 2) return;

    final names = <String>{};
    for (final item in payload) {
      if (item is Map) {
        final cls = item['class'];
        if (cls is String && cls.isNotEmpty) {
          names.add(cls);
        }
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

  Widget _buildPermissionScreen() {
    final statusText = _permissionMessage ?? 'Camera permission required';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt_outlined, size: 72),
            const SizedBox(height: 20),
            const Text(
              'Camera permission required',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              statusText,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _checkingPermission ? null : _checkAndRequestCameraPermission,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openingSettings ? null : _openSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidView() {
    return PlatformViewLink(
      viewType: 'arcore_yolo_view',
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'arcore_yolo_view',
          layoutDirection: TextDirection.ltr,
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener((id) {
            params.onPlatformViewCreated(id);
            _onArCorePlatformViewCreated(id);
          })
          ..create();
      },
    );
  }

  Widget _buildIosView() {
    return YOLOView(
      modelPath: 'yolo11n',
      task: YOLOTask.detect,
      confidenceThreshold: 0.3,
      onResult: _handleResults,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Computer Vision'),
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
      ),
      body: _checkingPermission
          ? const Center(child: CircularProgressIndicator())
          : !_cameraGranted
              ? _buildPermissionScreen()
              : Stack(
                  children: [
                    if (Platform.isAndroid) _buildAndroidView() else _buildIosView(),
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
                              ? 'Point the camera at something…'
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