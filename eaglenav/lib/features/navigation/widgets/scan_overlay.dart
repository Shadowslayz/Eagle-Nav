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

enum _IOSArrowsPhase { detect, segment }

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
  static const Duration _sceneFreshness = Duration(milliseconds: 2200);

  final Map<String, _SceneObservation?> _nearestHazards = {
    'AHEAD': null,
    'LEFT': null,
    'RIGHT': null,
  };
  final Map<String, _SceneWallObservation?> _nearestWalls = {
    'AHEAD': null,
    'LEFT': null,
    'RIGHT': null,
  };

  String _summaryText = 'Scanning environment…';
  String _activeDirection = '';
  double _threatLevel = 0.0;
  Timer? _summaryTimer;
  Timer? _iosPhaseTimer;
  String _lastSpokenSummary = '';
  bool _analysisComplete = false;

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
  _IOSArrowsPhase _iosArrowsPhase = _IOSArrowsPhase.detect;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _initTts();

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
        _startOneShotAnalysis();
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
    await _tts.awaitSpeakCompletion(true);
  }

  @override
  void dispose() {
    _tts.stop();
    _summaryTimer?.cancel();
    _iosPhaseTimer?.cancel();
    _pauseArCore(_arcoreDetectChannel);
    _pauseArCore(_arcoreSegChannel);
    super.dispose();
  }

  void _startOneShotAnalysis() {
    _analysisComplete = false;
    _summaryTimer?.cancel();
    _iosPhaseTimer?.cancel();

    if (Platform.isIOS) {
      _iosArrowsPhase = _IOSArrowsPhase.detect;
      _iosPhaseTimer = Timer(const Duration(milliseconds: 900), () {
        if (!mounted || _analysisComplete) return;
        setState(() {
          _iosArrowsPhase = _IOSArrowsPhase.segment;
        });
      });
      _summaryTimer = Timer(const Duration(milliseconds: 1900), () async {
        if (!mounted || _analysisComplete) return;
        await _finishOneShotAnalysis();
      });
      return;
    }

    _summaryTimer = Timer(const Duration(milliseconds: 2200), () async {
      if (!mounted || _analysisComplete) return;
      await _finishOneShotAnalysis();
    });
  }

  Future<void> _finishOneShotAnalysis() async {
    _analysisComplete = true;
    _summaryTimer?.cancel();
    _iosPhaseTimer?.cancel();
    await _buildAndSpeakSummary();
    if (!mounted) return;
    widget.onDismiss();
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

  Set<String> _wallDirectionsFromRect(Rect box) {
    final directions = <String>{};
    final spansAcrossPath = box.width >= 0.55;

    if (spansAcrossPath) {
      directions.add('AHEAD');
      if (box.left <= 0.18) directions.add('LEFT');
      if (box.right >= 0.82) directions.add('RIGHT');
      return directions;
    }

    directions.add(_directionFromRect(box));
    return directions;
  }

  double _area(Rect box) => box.width * box.height;

  int _urgency(double area) {
    if (area > 0.28) return 3;
    if (area > 0.12) return 2;
    if (area > 0.04) return 1;
    return 0;
  }

  bool _shouldKeepDetection(String className, double area) {
    if (_isWallLike(className)) {
      return _urgency(area) > 0;
    }
    if (_isPersonLike(className)) {
      return area > 0.008;
    }
    return area > 0.015;
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

  bool _isWallLike(String name) {
    final normalized = name.toLowerCase();
    return normalized.contains('wall');
  }

  bool _isPersonLike(String name) {
    final normalized = name.toLowerCase();
    return normalized == 'person' || normalized.contains('people');
  }

  bool _isNarrowObstacleLike(String name) {
    final normalized = name.toLowerCase();
    return normalized.contains('column') ||
        normalized.contains('pillar') ||
        normalized.contains('pole') ||
        normalized.contains('post') ||
        normalized.contains('bollard');
  }

  String _spokenLabel(String name) {
    final normalized = name.toLowerCase();
    if (_isPersonLike(normalized)) return 'person';
    if (_isNarrowObstacleLike(normalized)) return 'column';
    if (_isWallLike(normalized)) return 'wall';
    return normalized.replaceAll('_', ' ');
  }

  int? _distanceFeetValue(String raw) {
    if (raw.isEmpty) return null;
    final feetRegex = RegExp(r"(\d+)\s*(?:ft|\u2032|')");
    final inchRegex = RegExp(r'(\d+)\s*(?:in|\u2033|")');

    final feetMatch = feetRegex.firstMatch(raw);
    final inchMatch = inchRegex.firstMatch(raw);

    final feet = feetMatch != null ? int.tryParse(feetMatch.group(1)!) : null;
    final inches = inchMatch != null ? int.tryParse(inchMatch.group(1)!) : null;

    if (feet == null && inches == null) return null;

    var totalFeet = feet ?? 0;
    if (inches != null && inches >= 6) totalFeet += 1;
    return totalFeet <= 0 ? 1 : totalFeet;
  }

  int _distanceFeetFromRawOrArea(String raw, double area) {
    return _distanceFeetValue(raw) ?? _estimateFeetFromArea(area);
  }

  String _spokenDistance(String raw) {
    final feet = _distanceFeetValue(raw);
    if (feet == null) return '';
    if (feet <= 3) return 'a few feet';
    if (feet <= 6) return 'about $feet feet';
    return '$feet feet';
  }

  String _locationPhrase(String dir) {
    switch (dir) {
      case 'AHEAD':
        return 'ahead';
      case 'LEFT':
        return 'to your left';
      case 'RIGHT':
        return 'to your right';
      default:
        return '';
    }
  }

  bool _isBetterHazardCandidate(
    _SceneObservation candidate,
    _SceneObservation? current,
  ) {
    if (current == null) return true;

    final candidatePriority = _isPersonLike(candidate.className)
        ? 0
        : _isNarrowObstacleLike(candidate.className)
        ? 1
        : 2;
    final currentPriority = _isPersonLike(current.className)
        ? 0
        : _isNarrowObstacleLike(current.className)
        ? 1
        : 2;
    if (candidatePriority != currentPriority) {
      return candidatePriority < currentPriority;
    }

    if (candidate.feet != current.feet) {
      return candidate.feet < current.feet;
    }

    return candidate.area > current.area;
  }

  void _recordWall(String dir, int feet) {
    final now = DateTime.now();
    final current = _nearestWalls[dir];
    if (current == null || feet < current.feet) {
      _nearestWalls[dir] = _SceneWallObservation(feet: feet, updatedAt: now);
    }
  }

  void _recordHazard(String dir, String className, int feet, double area) {
    final candidate = _SceneObservation(
      className: className.toLowerCase(),
      feet: feet,
      area: area,
      updatedAt: DateTime.now(),
    );
    if (_isBetterHazardCandidate(candidate, _nearestHazards[dir])) {
      _nearestHazards[dir] = candidate;
    }
  }

  _SceneObservation? _freshHazard(String dir) {
    final hazard = _nearestHazards[dir];
    if (hazard == null) return null;
    if (DateTime.now().difference(hazard.updatedAt) > _sceneFreshness) {
      _nearestHazards[dir] = null;
      return null;
    }
    return hazard;
  }

  _SceneWallObservation? _freshWall(String dir) {
    final wall = _nearestWalls[dir];
    if (wall == null) return null;
    if (DateTime.now().difference(wall.updatedAt) > _sceneFreshness) {
      _nearestWalls[dir] = null;
      return null;
    }
    return wall;
  }

  void _clearSceneState() {
    for (final key in _nearestHazards.keys) {
      _nearestHazards[key] = null;
      _nearestWalls[key] = null;
    }
  }

  String? _safeDirectionRecommendation() {
    int scoreFor(String dir) {
      var score = 100;
      final wallFeet = _freshWall(dir)?.feet;
      final hazard = _freshHazard(dir);

      if (wallFeet != null) {
        if (wallFeet <= 3) {
          score -= 70;
        } else if (wallFeet <= 5) {
          score -= 45;
        } else if (wallFeet <= 8) {
          score -= 25;
        } else {
          score -= 10;
        }
      } else {
        score += 10;
      }

      if (hazard != null) {
        final isNarrow = _isNarrowObstacleLike(hazard.className);
        if (hazard.feet <= 3) {
          score -= isNarrow ? 70 : 55;
        } else if (hazard.feet <= 6) {
          score -= isNarrow ? 50 : 35;
        } else {
          score -= isNarrow ? 25 : 15;
        }
      }

      return score;
    }

    bool hasPositiveEvidence(String dir) {
      final wallFeet = _freshWall(dir)?.feet;
      final hazard = _freshHazard(dir);
      final wallOk = wallFeet == null || wallFeet >= 8;
      final hazardOk = hazard == null || hazard.feet >= 8;
      return wallOk && hazardOk;
    }

    final leftScore = scoreFor('LEFT');
    final rightScore = scoreFor('RIGHT');
    if ((leftScore - rightScore).abs() < 25) return null;

    final recommended = leftScore > rightScore ? 'left' : 'right';
    return hasPositiveEvidence(recommended) ? recommended : null;
  }

  void _updateThreatAndDirection(String dir, double area) {
    setState(() {
      _threatLevel = (area / 0.35).clamp(0.0, 1.0);
      _activeDirection = dir;
    });
    _triggerHaptics(_urgency(area));
  }

  // iOS behavior from file 2
  void _handleIOSArrowsResults(List<YOLOResult> results) {
    if (!mounted || !_isArrowsMode || _analysisComplete) return;

    final relevant = results
        .where(
          (r) =>
              r.className.isNotEmpty &&
              !_ignored.contains(r.className.toLowerCase()) &&
              _isWallLike(r.className),
        )
        .toList();

    if (relevant.isEmpty) return;

    relevant.sort(
      (a, b) => _area(b.normalizedBox).compareTo(_area(a.normalizedBox)),
    );

    for (final r in relevant) {
      final area = _area(r.normalizedBox);
      if (_urgency(area) == 0) continue;

      String distStr;
      try {
        final lidar = (r as dynamic).distanceText as String?;
        distStr = (lidar != null && lidar.isNotEmpty)
            ? lidar
            : '${_estimateFeetFromArea(area)}ft';
      } catch (_) {
        distStr = '${_estimateFeetFromArea(area)}ft';
      }
      final feet = _distanceFeetFromRawOrArea(distStr, area);
      for (final dir in _wallDirectionsFromRect(r.normalizedBox)) {
        _recordWall(dir, feet);
      }
    }

    final topArea = _area(relevant.first.normalizedBox);
    final topDir = _directionFromRect(relevant.first.normalizedBox);
    _updateThreatAndDirection(topDir, topArea);
  }

  void _handleDetectResults(List<YOLOResult> results) {
    if (_analysisComplete) return;
    _processResults(results, wallsOnly: false);
  }

  void _handleSegResults(List<YOLOResult> results) {
    if (_analysisComplete) return;
    _processResults(results, wallsOnly: true);
  }

  // Android behavior from file 1
  void _processResults(List<YOLOResult> results, {required bool wallsOnly}) {
    if (!mounted || _analysisComplete) return;

    final relevant = results
        .where(
          (r) =>
              r.className.isNotEmpty &&
              !_ignored.contains(r.className.toLowerCase()) &&
              (wallsOnly
                  ? _isWallLike(r.className)
                  : !_isWallLike(r.className)),
        )
        .toList();

    if (relevant.isEmpty) return;

    relevant.sort(
      (a, b) => _area(b.normalizedBox).compareTo(_area(a.normalizedBox)),
    );

    for (final r in relevant) {
      final area = _area(r.normalizedBox);
      if (!_shouldKeepDetection(r.className, area)) continue;

      String distStr;
      try {
        final lidar = (r as dynamic).distanceText as String?;
        distStr = (lidar != null && lidar.isNotEmpty)
            ? lidar
            : '${_estimateFeetFromArea(area)}ft';
      } catch (_) {
        distStr = '${_estimateFeetFromArea(area)}ft';
      }
      final feet = _distanceFeetFromRawOrArea(distStr, area);
      if (wallsOnly) {
        for (final dir in _wallDirectionsFromRect(r.normalizedBox)) {
          _recordWall(dir, feet);
        }
      } else {
        final dir = _directionFromRect(r.normalizedBox);
        _recordHazard(dir, r.className, feet, area);
      }
    }

    final topArea = _area(relevant.first.normalizedBox);
    final topDir = _directionFromRect(relevant.first.normalizedBox);
    _updateThreatAndDirection(topDir, topArea);
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
    if (!mounted || payload.isEmpty || _analysisComplete) return;

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

      items.add(
        _ArDetection(
          className: cls,
          cx: x + w / 2,
          area: w * h,
          distanceText: distText,
        ),
      );
    }

    if (items.isEmpty) return;
    items.sort((a, b) => b.area.compareTo(a.area));

    for (final d in items) {
      final hasDist = d.distanceText.isNotEmpty;
      if (!hasDist && _urgency(d.area) == 0) continue;
      final dir = _directionFromNormalizedCx(d.cx);
      final distStr = hasDist
          ? d.distanceText
          : '${_estimateFeetFromArea(d.area)}ft';
      _recordHazard(
        dir,
        d.className,
        _distanceFeetFromRawOrArea(distStr, d.area),
        d.area,
      );
    }

    final top = items.first;
    _updateThreatAndDirection(_directionFromNormalizedCx(top.cx), top.area);
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

  Future<void> _buildAndSpeakSummary() async {
    final parts = <String>[];
    final aheadHazard = _freshHazard('AHEAD');
    final leftHazard = _freshHazard('LEFT');
    final rightHazard = _freshHazard('RIGHT');
    final aheadWall = _freshWall('AHEAD')?.feet;
    final leftWall = _freshWall('LEFT')?.feet;
    final rightWall = _freshWall('RIGHT')?.feet;

    if (aheadHazard != null) {
      final distance = _spokenDistance('${aheadHazard.feet}ft');
      parts.add(
        distance.isEmpty
            ? '${_spokenLabel(aheadHazard.className)} ahead'
            : '${_spokenLabel(aheadHazard.className)} $distance ahead',
      );
    } else if (aheadWall != null && aheadWall <= 4) {
      parts.add('wall very close ahead');
    } else {
      parts.add('path mostly clear ahead');
    }

    if (leftWall != null && rightWall != null) {
      if (leftWall <= 5 && rightWall <= 5) {
        parts.add('walls close on both sides');
      } else {
        parts.add('walls on both sides');
      }
    } else {
      if (leftWall != null) {
        parts.add(
          leftWall <= 4 ? 'wall close on your left' : 'wall on your left',
        );
      }
      if (rightWall != null) {
        parts.add(
          rightWall <= 4 ? 'wall close on your right' : 'wall on your right',
        );
      }
    }

    for (final entry in [('LEFT', leftHazard), ('RIGHT', rightHazard)]) {
      final dir = entry.$1;
      final hazard = entry.$2;
      if (hazard == null) continue;
      if (hazard.feet > 6) continue;
      final distance = _spokenDistance('${hazard.feet}ft');
      final location = _locationPhrase(dir);
      parts.add(
        distance.isEmpty
            ? '${_spokenLabel(hazard.className)} $location'
            : '${_spokenLabel(hazard.className)} $distance $location',
      );
    }

    final recommendation = _safeDirectionRecommendation();
    if (recommendation != null) {
      parts.add('more room on your $recommendation');
    }

    _clearSceneState();

    final text = parts.isEmpty ? 'Path mostly clear' : parts.join(', ');

    setState(() {
      _summaryText = _capitalize(text);
      if (parts.isEmpty) {
        _threatLevel = 0.0;
        _activeDirection = '';
      }
    });

    if (text == _lastSpokenSummary) return;
    _lastSpokenSummary = text;

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
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.25)),
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
                        'Analyzes once per tap',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
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
                          task: _showSegDebug
                              ? YOLOTask.segment
                              : YOLOTask.detect,
                          confidenceThreshold: 0.35,
                          showOverlays: true,
                          onResult: _showSegDebug
                              ? _handleSegResults
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
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.25)),
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
                        color:
                            _summaryText == 'Path clear' ||
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
                      ? Positioned(
                          left: 0,
                          top: 0,
                          width: 1,
                          height: 1,
                          child: IgnorePointer(
                            child: Opacity(
                              opacity: 0.0,
                              child: YOLOView(
                                key: ValueKey(
                                  _iosArrowsPhase == _IOSArrowsPhase.detect
                                      ? 'ios_scan_detect_hidden'
                                      : 'ios_scan_seg_hidden',
                                ),
                                modelPath:
                                    _iosArrowsPhase == _IOSArrowsPhase.detect
                                    ? detectModel
                                    : segModel,
                                task: _iosArrowsPhase == _IOSArrowsPhase.detect
                                    ? YOLOTask.detect
                                    : YOLOTask.segment,
                                confidenceThreshold:
                                    _iosArrowsPhase == _IOSArrowsPhase.detect
                                    ? 0.20
                                    : 0.35,
                                showOverlays: false,
                                onResult:
                                    _iosArrowsPhase == _IOSArrowsPhase.detect
                                    ? _handleDetectResults
                                    : _handleIOSArrowsResults,
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
                          style: Theme.of(
                            context,
                          ).textTheme.titleLarge?.copyWith(color: Colors.white),
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
                  child: CircularProgressIndicator(color: Color(0xFFC9A227)),
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
                          'Analyzes once per tap',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
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
                        _showIOSDebugCamera
                            ? 'Hide iOS Debug'
                            : 'Show iOS Debug',
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
                          color:
                              _summaryText == 'Path clear' ||
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

class _SceneObservation {
  final String className;
  final int feet;
  final double area;
  final DateTime updatedAt;

  const _SceneObservation({
    required this.className,
    required this.feet,
    required this.area,
    required this.updatedAt,
  });
}

class _SceneWallObservation {
  final int feet;
  final DateTime updatedAt;

  const _SceneWallObservation({required this.feet, required this.updatedAt});
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
        color: active
            ? color.withOpacity(0.22)
            : Colors.white.withOpacity(0.07),
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
