import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scan modes triggered from the Scan button on the navigation screen.
/// - single tap → arrows overlay
///     • iOS: full-screen transparent overlay (map shows through)
///     • Android: keep the existing working dual-YOLO setup
/// - long press → full object detection screen on both platforms
enum ScanMode { arrowsSegment, fullDetect }

class ScanOverlay extends StatefulWidget {
  final VoidCallback onDismiss;
  final ScanMode mode;

  const ScanOverlay({
    super.key,
    required this.onDismiss,
    this.mode = ScanMode.arrowsSegment,
  });

  @override
  State<ScanOverlay> createState() => _ScanOverlayState();
}

class _ScanOverlayState extends State<ScanOverlay> {
  final FlutterTts _tts = FlutterTts();

  final Map<String, Map<String, String>> _buffer = {
    'AHEAD': {},
    'LEFT': {},
    'RIGHT': {},
  };

  String _summaryText = 'Scanning environment…';
  String _activeDirection = '';
  double _threatLevel = 0.0;
  Timer? _summaryTimer;

  MethodChannel? _arcoreDetectChannel;
  MethodChannel? _arcoreSegChannel;

  bool _isReady = false;
  bool _hasError = false;
  String _errorMessage = '';

  static const Set<String> _ignored = {
    'ceiling',
    'floor',
    'sky',
    'road',
    'sidewalk',
    'ground',
    'pavement',
  };

  bool get _isArrowsMode => widget.mode == ScanMode.arrowsSegment;
  bool _developerMode = false;
  bool _showDebugButton = true;
  bool _showDebugCamera = false;
  bool _showIOSDebugCamera = false;
  bool _showSegDebug = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _initTts();

      if (Platform.isAndroid) {
        final granted = await _ensureCameraPermission();
        if (!mounted) return;
        if (!granted) {
          setState(() {
            _hasError = true;
            _errorMessage = 'Camera permission required.';
            _isReady = false;
          });
          return;
        }
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      final prefs = await SharedPreferences.getInstance();
      _developerMode = prefs.getBool('developerMode') ?? false;
      _showDebugButton = prefs.getBool('showScanDebugButton') ?? true;

      setState(() => _isReady = true);

      if (!_developerMode || !_showDebugButton) {
        _showDebugCamera = false;
        _showIOSDebugCamera = false;
      }

      if (_isArrowsMode) {
        _scheduleSummary();
      }
    } catch (e) {
      debugPrint('ScanOverlay init: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Failed to initialize: $e';
        });
      }
    }
  }

  Future<bool> _ensureCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted) return true;
    status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.50);
    await _tts.setVolume(1.0);
  }

  @override
  void dispose() {
    _tts.stop();
    _summaryTimer?.cancel();
    _pauseArCore(_arcoreDetectChannel);
    _pauseArCore(_arcoreSegChannel);
    super.dispose();
  }

  Future<void> _pauseArCore(MethodChannel? c) async {
    if (c == null) return;
    try {
      await c.invokeMethod('pause');
    } catch (e) {
      debugPrint('ARCore pause: $e');
    }
  }

  Future<void> _resumeArCore(MethodChannel? c) async {
    if (c == null) return;
    try {
      await c.invokeMethod('resume');
    } catch (e) {
      debugPrint('ARCore resume: $e');
    }
  }

  String _directionFromNormalizedCx(double cx) {
    if (cx < 0.33) return 'LEFT';
    if (cx > 0.67) return 'RIGHT';
    return 'AHEAD';
  }

  String _directionFromRect(Rect box) {
    final cx = box.left + box.width / 2;
    return _directionFromNormalizedCx(cx);
  }

  double _area(Rect box) => box.width * box.height;

  int _urgency(double area) {
    if (area > 0.28) return 3;
    if (area > 0.12) return 2;
    if (area > 0.04) return 1;
    return 0;
  }

  int _estimateFeetFromArea(double area) {
    if (area >= 0.35) return 2;
    if (area >= 0.25) return 3;
    if (area >= 0.18) return 4;
    if (area >= 0.12) return 5;
    if (area >= 0.08) return 7;
    if (area >= 0.05) return 10;
    if (area >= 0.03) return 12;
    return 15;
  }

  String _toFeetOnly(String raw) {
    if (raw.isEmpty) return '';
    final feetRegex = RegExp(r"(\d+)\s*(?:ft|\u2032|')");
    final inchRegex = RegExp(r'(\d+)\s*(?:in|\u2033|")');

    int? feet;
    int? inches;

    final feetMatch = feetRegex.firstMatch(raw);
    if (feetMatch != null) feet = int.tryParse(feetMatch.group(1)!);
    final inchMatch = inchRegex.firstMatch(raw);
    if (inchMatch != null) inches = int.tryParse(inchMatch.group(1)!);

    if (feet == null && inches == null) return raw.trim();

    int totalFeet = feet ?? 0;
    if (inches != null && inches >= 6) totalFeet += 1;
    if (totalFeet <= 0) totalFeet = 1;
    return '${totalFeet}ft';
  }

  // iOS behavior from file 2
  void _handleIOSArrowsResults(List<YOLOResult> results) {
    if (!mounted || !_isArrowsMode) return;

    final relevant = results.where((r) =>
        r.className.isNotEmpty &&
        !_ignored.contains(r.className.toLowerCase())).toList();

    if (relevant.isEmpty) return;

    relevant.sort(
      (a, b) => _area(b.normalizedBox).compareTo(_area(a.normalizedBox)),
    );

    for (final r in relevant) {
      final area = _area(r.normalizedBox);
      if (_urgency(area) == 0) continue;
      final dir = _directionFromRect(r.normalizedBox);

      String distStr;
      try {
        final lidar = (r as dynamic).distanceText as String?;
        distStr = (lidar != null && lidar.isNotEmpty)
            ? lidar
            : '${_estimateFeetFromArea(area)}ft';
      } catch (_) {
        distStr = '${_estimateFeetFromArea(area)}ft';
      }

      _buffer[dir]?[r.className.toLowerCase()] = distStr;
    }

    final topArea = _area(relevant.first.normalizedBox);
    final topDir = _directionFromRect(relevant.first.normalizedBox);

    setState(() {
      _threatLevel = (topArea / 0.35).clamp(0.0, 1.0);
      _activeDirection = topDir;
    });

    _triggerHaptics(_urgency(topArea));
  }

  void _handleDetectResults(List<YOLOResult> results) {
    _processResults(results);
  }

  void _handleSegResults(List<YOLOResult> results) {
    _processResults(results);
  }

  // Android behavior from file 1
  void _processResults(List<YOLOResult> results) {
    if (!mounted) return;

    final relevant = results.where((r) =>
        r.className.isNotEmpty &&
        !_ignored.contains(r.className.toLowerCase())).toList();

    if (relevant.isEmpty) return;

    relevant.sort(
      (a, b) => _area(b.normalizedBox).compareTo(_area(a.normalizedBox)),
    );

    for (final r in relevant) {
      final area = _area(r.normalizedBox);
      if (_urgency(area) == 0) continue;
      final dir = _directionFromRect(r.normalizedBox);

      String distStr;
      try {
        final lidar = (r as dynamic).distanceText as String?;
        distStr = (lidar != null && lidar.isNotEmpty)
            ? lidar
            : '${_estimateFeetFromArea(area)}ft';
      } catch (_) {
        distStr = '${_estimateFeetFromArea(area)}ft';
      }

      _buffer[dir]?[r.className.toLowerCase()] = distStr;
    }

    final topArea = _area(relevant.first.normalizedBox);
    final topDir = _directionFromRect(relevant.first.normalizedBox);

    setState(() {
      _threatLevel = (topArea / 0.35).clamp(0.0, 1.0);
      _activeDirection = topDir;
    });

    _triggerHaptics(_urgency(topArea));
  }

  void _onArCoreDetectViewCreated(int viewId) {
    final channel = MethodChannel('arcore_yolo_view_$viewId');
    _arcoreDetectChannel = channel;
    channel.setMethodCallHandler((call) async {});
    _resumeArCore(channel);
  }

  void _onArCoreSegViewCreated(int viewId) {
    final channel = MethodChannel('arcore_seg_view_$viewId');
    _arcoreSegChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'onDetections') return;
      if (!_isArrowsMode) return;
      final arguments = call.arguments;
      final payload = arguments is List
          ? List<dynamic>.from(arguments)
          : const <dynamic>[];
      _processAndroidPayloadForArrows(payload);
    });
    _resumeArCore(channel);
  }

  void _processAndroidPayloadForArrows(List<dynamic> payload) {
    if (!mounted || payload.isEmpty) return;

    final items = <_ArDetection>[];
    for (final raw in payload) {
      if (raw is! Map) continue;
      final cls = (raw['class'] as String?)?.toLowerCase() ?? '';
      if (cls.isEmpty) continue;
      if (_ignored.contains(cls)) continue;

      final x = (raw['x'] as num?)?.toDouble() ?? 0.0;
      final w = (raw['w'] as num?)?.toDouble() ?? 0.0;
      final h = (raw['h'] as num?)?.toDouble() ?? 0.0;
      final distText = (raw['distance_text'] as String?) ?? '';

      items.add(_ArDetection(
        className: cls,
        cx: x + w / 2,
        area: w * h,
        distanceText: distText,
      ));
    }

    if (items.isEmpty) return;
    items.sort((a, b) => b.area.compareTo(a.area));

    for (final d in items) {
      final hasDist = d.distanceText.isNotEmpty;
      if (!hasDist && _urgency(d.area) == 0) continue;
      final dir = _directionFromNormalizedCx(d.cx);
      final distStr =
          hasDist ? d.distanceText : '${_estimateFeetFromArea(d.area)}ft';
      _buffer[dir]?[d.className] = distStr;
    }

    final top = items.first;
    setState(() {
      _threatLevel = (top.area / 0.35).clamp(0.0, 1.0);
      _activeDirection = _directionFromNormalizedCx(top.cx);
    });

    _triggerHaptics(_urgency(top.area));
  }

  void _triggerHaptics(int urgency) {
    if (urgency >= 3) {
      HapticFeedback.heavyImpact();
      Future.delayed(
        const Duration(milliseconds: 130),
        HapticFeedback.heavyImpact,
      );
    } else if (urgency == 2) {
      HapticFeedback.mediumImpact();
    }
  }

  void _scheduleSummary() {
    _summaryTimer = Timer(const Duration(seconds: 5), _announceAndReschedule);
  }

  Future<void> _announceAndReschedule() async {
    if (!mounted) return;
    await _buildAndSpeakSummary();
    _scheduleSummary();
  }

  Future<void> _buildAndSpeakSummary() async {
    final parts = <String>[];

    for (final dir in ['AHEAD', 'LEFT', 'RIGHT']) {
      final items = _buffer[dir];
      if (items == null || items.isEmpty) continue;

      final entries = items.entries.take(2).toList();
      final pieces = <String>[];

      for (final e in entries) {
        final name = e.key;
        final feetOnly = _toFeetOnly(e.value);

        String locationPhrase;
        if (dir == 'AHEAD') {
          locationPhrase = 'ahead';
        } else if (dir == 'LEFT') {
          locationPhrase = 'on your left';
        } else {
          locationPhrase = 'on your right';
        }

        if (feetOnly.isEmpty) {
          pieces.add('$name $locationPhrase');
        } else {
          pieces.add('$name $feetOnly $locationPhrase');
        }
      }

      parts.addAll(pieces);
    }

    _buffer.forEach((k, v) => v.clear());

    final text = parts.isEmpty ? 'Path clear' : parts.join(', ');

    setState(() {
      _summaryText = _capitalize(text);
      if (parts.isEmpty) {
        _threatLevel = 0.0;
        _activeDirection = '';
      }
    });

    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS: $e');
    }
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Color get _threatColor {
    if (_threatLevel > 0.72) return Colors.red;
    if (_threatLevel > 0.38) return Colors.orange;
    return const Color(0xFFC9A227);
  }

  String get _modeTitle {
    switch (widget.mode) {
      case ScanMode.arrowsSegment:
        return 'Obstacle Scan';
      case ScanMode.fullDetect:
        return 'Objects + Distance + Size';
    }
  }

  IconData get _modeIcon {
    switch (widget.mode) {
      case ScanMode.arrowsSegment:
        return Icons.radar;
      case ScanMode.fullDetect:
        return Icons.center_focus_strong;
    }
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _errorMessage = '';
      _isReady = false;
    });
    _init();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return _buildAndroidFromFile1(context);
    }
    return _buildIOSFromFile2(context);
  }

  // Android from file 1
  Widget _buildAndroidFromFile1(BuildContext context) {
    final detectModel = 'yolo11n.tflite';
    final segModel = 'yolo11n-seg.tflite';
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    final debugPanelHeight = screenHeight * 0.38;

    return GestureDetector(
      onTap: widget.onDismiss,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          // Hidden detection logic still runs
          if (!_showDebugCamera)
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: YOLOView(
                key: const ValueKey('scan_detect_hidden'),
                modelPath: detectModel,
                task: YOLOTask.detect,
                confidenceThreshold: 0.35,
                showOverlays: false,
                onResult: _handleDetectResults,
              ),
            ),

          // Hidden segmentation logic still runs unless visible seg debug is open
          if (!_showDebugCamera || !_showSegDebug)
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: YOLOView(
                key: const ValueKey('scan_seg_hidden'),
                modelPath: segModel,
                task: YOLOTask.segment,
                confidenceThreshold: 0.35,
                showOverlays: false,
                onResult: _handleSegResults,
              ),
            ),

          if (_threatLevel > 0.45)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _threatColor.withOpacity(0.7 * _threatLevel),
                      width: 6,
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(20, topPad + 12, 20, 16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.25),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC9A227).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(
                      Icons.radar,
                      color: Color(0xFFC9A227),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Obstacle Scan',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Summarizes every 5 seconds',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: widget.onDismiss,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Text(
                        'Done',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Developer-only debug toggle
          if (_developerMode && _showDebugButton)
            Positioned(
              top: topPad + 78,
              right: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _showDebugCamera = !_showDebugCamera;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        _showDebugCamera ? 'Hide Debug' : 'Show Debug',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  if (_showDebugCamera)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _showSegDebug = !_showSegDebug;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          _showSegDebug ? 'Mode: Segment' : 'Mode: Detect',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // Developer debug camera panel
          if (_developerMode && _showDebugCamera)
            Positioned(
              left: 16,
              right: 16,
              bottom: botPad + 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  height: debugPanelHeight,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(
                      color: const Color(0xFFC9A227).withOpacity(0.7),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                      child: YOLOView(
                        key: ValueKey(
                          _showSegDebug
                              ? 'scan_seg_debug_visible'
                              : 'scan_detect_debug_visible',
                        ),
                        modelPath: _showSegDebug ? segModel : detectModel,
                        task: _showSegDebug ? YOLOTask.segment : YOLOTask.detect,
                        confidenceThreshold: 0.35,
                        showOverlays: true,
                        onResult:
                            _showSegDebug ? _handleSegResults : _handleDetectResults,
                      ),
                      ),
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Developer Debug View',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 28, 24, botPad + 28),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.25),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DirectionRow(
                    activeDirection: _activeDirection,
                    color: _threatColor,
                  ),
                  const SizedBox(height: 16),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _summaryText,
                      key: ValueKey(_summaryText),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _summaryText == 'Path clear' ||
                                _summaryText == 'Scanning environment…'
                            ? Colors.white70
                            : Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Tap anywhere to close',
                    style: TextStyle(
                      color: Colors.white30,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // iOS from file 2
  Widget _buildIOSFromFile2(BuildContext context) {
    final detectModel = 'yolo11n';
    final segModel = 'yolo11n-seg';
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;
    final debugPanelHeight = MediaQuery.of(context).size.height * 0.38;

    return GestureDetector(
      onTap: widget.onDismiss,
      child: Stack(
        children: [
          if (_isReady && !_hasError)
            _isArrowsMode
                ? (!_showIOSDebugCamera
                    ? Positioned.fill(
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: 0.0,
                            child: _PrimaryCameraView(
                              mode: widget.mode,
                              detectModel: detectModel,
                              segModel: segModel,
                              onIOSArrowsResult: _handleIOSArrowsResults,
                              onAndroidDetectViewCreated:
                                  _onArCoreDetectViewCreated,
                              onAndroidSegViewCreated: _onArCoreSegViewCreated,
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink())
                : Positioned.fill(
                    child: IgnorePointer(
                      child: _PrimaryCameraView(
                        mode: widget.mode,
                        detectModel: detectModel,
                        segModel: segModel,
                        onIOSArrowsResult: _handleIOSArrowsResults,
                        onAndroidDetectViewCreated: _onArCoreDetectViewCreated,
                        onAndroidSegViewCreated: _onArCoreSegViewCreated,
                      ),
                    ),
                  ),

          if (_isArrowsMode && _isReady && !_hasError)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.3,
                      colors: [
                        _threatColor.withOpacity(0.10),
                        _threatColor.withOpacity(0.28),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          if (_hasError)
            Positioned.fill(
              child: Container(
                color: Colors.black87,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Camera failed to start',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(color: Colors.white),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _errorMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          if (!_isReady && !_hasError)
            const Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: CircularProgressIndicator(
                    color: Color(0xFFC9A227),
                  ),
                ),
              ),
            ),

          if (_isArrowsMode && _threatLevel > 0.45)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _threatColor.withOpacity(0.7 * _threatLevel),
                      width: 6,
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(20, topPad + 12, 20, 16),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC9A227).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      _modeIcon,
                      color: const Color(0xFFC9A227),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _modeTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_isArrowsMode)
                        const Text(
                          'Summarizes every 5 seconds',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: widget.onDismiss,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Text(
                        'Done',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_developerMode && _showDebugButton && _isArrowsMode)
            Positioned(
              top: topPad + 78,
              right: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _showIOSDebugCamera = !_showIOSDebugCamera;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        _showIOSDebugCamera ? 'Hide iOS Debug' : 'Show iOS Debug',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_showIOSDebugCamera)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _showSegDebug = !_showSegDebug;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          _showSegDebug ? 'Mode: Segment' : 'Mode: Detect',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          if (_developerMode &&
              _showDebugButton &&
              _showIOSDebugCamera &&
              _isArrowsMode)
            Positioned(
              left: 16,
              right: 16,
              bottom: botPad + 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  height: debugPanelHeight,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(
                      color: const Color(0xFFC9A227).withOpacity(0.7),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: YOLOView(
                          key: ValueKey(
                            _showSegDebug
                                ? 'ios_seg_debug_visible'
                                : 'ios_detect_debug_visible',
                          ),
                          modelPath: _showSegDebug ? segModel : detectModel,
                          task: _showSegDebug
                              ? YOLOTask.segment
                              : YOLOTask.detect,
                          confidenceThreshold: 0.55,
                          showOverlays: true,
                          onResult: _showSegDebug
                              ? _handleIOSArrowsResults
                              : _handleDetectResults,
                        ),
                      ),
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _showSegDebug
                                ? 'iOS Debug View - Segment'
                                : 'iOS Debug View - Detect',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 28, 24, botPad + 28),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isArrowsMode) ...[
                    _DirectionRow(
                      activeDirection: _activeDirection,
                      color: _threatColor,
                    ),
                    const SizedBox(height: 16),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        _summaryText,
                        key: ValueKey(_summaryText),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _summaryText == 'Path clear' ||
                                  _summaryText == 'Scanning environment…'
                              ? Colors.white70
                              : Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Text(
                    'Tap anywhere to close',
                    style: TextStyle(color: Colors.white30, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryCameraView extends StatelessWidget {
  final ScanMode mode;
  final String detectModel;
  final String segModel;
  final void Function(List<YOLOResult>) onIOSArrowsResult;
  final ValueChanged<int> onAndroidDetectViewCreated;
  final ValueChanged<int> onAndroidSegViewCreated;

  const _PrimaryCameraView({
    required this.mode,
    required this.detectModel,
    required this.segModel,
    required this.onIOSArrowsResult,
    required this.onAndroidDetectViewCreated,
    required this.onAndroidSegViewCreated,
  });

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      switch (mode) {
        case ScanMode.arrowsSegment:
          return _AndroidArCoreSegView(
            onPlatformViewCreated: onAndroidSegViewCreated,
          );
        case ScanMode.fullDetect:
          return _AndroidArCoreYoloView(
            onPlatformViewCreated: onAndroidDetectViewCreated,
          );
      }
    }

    switch (mode) {
      case ScanMode.arrowsSegment:
        return YOLOView(
          key: const ValueKey('scan_arrows_yolo'),
          modelPath: segModel,
          task: YOLOTask.segment,
          confidenceThreshold: 0.55,
          showOverlays: false,
          onResult: onIOSArrowsResult,
        );
      case ScanMode.fullDetect:
        return YOLOView(
          key: const ValueKey('scan_full_detect_yolo'),
          modelPath: detectModel,
          task: YOLOTask.detect,
          confidenceThreshold: 0.55,
          showOverlays: true,
          onResult: (_) {},
        );
    }
  }
}

class _AndroidArCoreYoloView extends StatelessWidget {
  final ValueChanged<int> onPlatformViewCreated;
  const _AndroidArCoreYoloView({required this.onPlatformViewCreated});

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      key: const ValueKey('scan_android_arcore_yolo_view'),
      viewType: 'arcore_yolo_view',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'arcore_yolo_view',
          layoutDirection: TextDirection.ltr,
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener((viewId) {
          params.onPlatformViewCreated(viewId);
          onPlatformViewCreated(viewId);
        });
        controller.create();
        return controller;
      },
    );
  }
}

class _AndroidArCoreSegView extends StatelessWidget {
  final ValueChanged<int> onPlatformViewCreated;
  const _AndroidArCoreSegView({required this.onPlatformViewCreated});

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      key: const ValueKey('scan_android_arcore_seg_view'),
      viewType: 'arcore_seg_view',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'arcore_seg_view',
          layoutDirection: TextDirection.ltr,
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener((viewId) {
          params.onPlatformViewCreated(viewId);
          onPlatformViewCreated(viewId);
        });
        controller.create();
        return controller;
      },
    );
  }
}

class _ArDetection {
  final String className;
  final double cx;
  final double area;
  final String distanceText;

  _ArDetection({
    required this.className,
    required this.cx,
    required this.area,
    required this.distanceText,
  });
}

class _DirectionRow extends StatelessWidget {
  final String activeDirection;
  final Color color;

  const _DirectionRow({required this.activeDirection, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Arrow(
          icon: Icons.arrow_back_rounded,
          active: activeDirection == 'LEFT',
          color: color,
        ),
        const SizedBox(width: 12),
        _Arrow(
          icon: Icons.arrow_upward_rounded,
          active: activeDirection == 'AHEAD',
          color: color,
        ),
        const SizedBox(width: 12),
        _Arrow(
          icon: Icons.arrow_forward_rounded,
          active: activeDirection == 'RIGHT',
          color: color,
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color color;

  const _Arrow({required this.icon, required this.active, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: active ? 56 : 44,
      height: active ? 56 : 44,
      decoration: BoxDecoration(
        color: active ? color.withOpacity(0.22) : Colors.white.withOpacity(0.07),
        shape: BoxShape.circle,
        border: Border.all(
          color: active ? color : Colors.white24,
          width: active ? 2.5 : 1,
        ),
      ),
      child: Icon(
        icon,
        color: active ? color : Colors.white30,
        size: active ? 26 : 20,
      ),
    );
  }
}