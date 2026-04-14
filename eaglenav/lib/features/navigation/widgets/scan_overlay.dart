import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class ScanOverlay extends StatefulWidget {
  final VoidCallback onDismiss;

  const ScanOverlay({super.key, required this.onDismiss});

  @override
  State<ScanOverlay> createState() => _ScanOverlayState();
}

class _ScanOverlayState extends State<ScanOverlay> {
  final FlutterTts _tts = FlutterTts();

  // Rolling detection buffer: direction → objects seen
  final Map<String, Set<String>> _buffer = {
    'AHEAD': {},
    'LEFT': {},
    'RIGHT': {},
  };

  // What was in the last summary (for display)
  String _summaryText = 'Scanning environment…';
  String _activeDirection = '';
  double _threatLevel = 0.0;
  Timer? _summaryTimer;

  // Classes not worth announcing while walking
  static const Set<String> _ignored = {
    'ceiling', 'floor', 'sky', 'road', 'sidewalk', 'ground', 'pavement',
  };

  @override
  void initState() {
    super.initState();
    _initTts();
    _scheduleSummary();
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
    super.dispose();
  }

  // ── Spatial helpers ───────────────────────────────────────────────────────

  String _directionFrom(Rect box) {
    final cx = box.left + box.width / 2;
    if (cx < 0.33) return 'LEFT';
    if (cx > 0.67) return 'RIGHT';
    return 'AHEAD';
  }

  double _area(Rect box) => box.width * box.height;

  int _urgency(double area) {
    if (area > 0.28) return 3; // stop
    if (area > 0.12) return 2; // close
    if (area > 0.04) return 1; // heads-up
    return 0;
  }

  // ── Detection handlers ────────────────────────────────────────────────────

  void _handleDetectResults(List<YOLOResult> results) {
    _processResults(results);
  }

  void _handleSegResults(List<YOLOResult> results) {
    _processResults(results);
  }

  void _processResults(List<YOLOResult> results) {
    if (!mounted) return;

    final relevant = results.where((r) =>
        r.className.isNotEmpty &&
        !_ignored.contains(r.className.toLowerCase())).toList();

    if (relevant.isEmpty) return;

    // Sort by proximity (largest area = closest)
    relevant.sort((a, b) =>
        _area(b.normalizedBox).compareTo(_area(a.normalizedBox)));

    // Add all visible objects to the rolling buffer
    for (final r in relevant) {
      final area = _area(r.normalizedBox);
      if (_urgency(area) == 0) continue;
      final dir = _directionFrom(r.normalizedBox);
      _buffer[dir]?.add(r.className.toLowerCase());
    }

    // Immediate safety haptic for stop-level threat (no TTS — summary handles speech)
    final topArea = _area(relevant.first.normalizedBox);
    final topDir = _directionFrom(relevant.first.normalizedBox);

    setState(() {
      _threatLevel = (topArea / 0.35).clamp(0.0, 1.0);
      _activeDirection = topDir;
    });

    if (_urgency(topArea) >= 3) {
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 130), HapticFeedback.heavyImpact);
    } else if (_urgency(topArea) == 2) {
      HapticFeedback.mediumImpact();
    }
  }

  // ── Periodic environment summary ──────────────────────────────────────────

  void _scheduleSummary() {
    _summaryTimer = Timer(const Duration(seconds: 4), _announceAndReschedule);
  }

  Future<void> _announceAndReschedule() async {
    if (!mounted) return;
    await _buildAndSpeakSummary();
    _scheduleSummary();
  }

  Future<void> _buildAndSpeakSummary() async {
    final parts = <String>[];

    // Priority order: AHEAD is most critical, then sides
    for (final dir in ['AHEAD', 'LEFT', 'RIGHT']) {
      final items = _buffer[dir];
      if (items == null || items.isEmpty) continue;

      // Take top 2 unique objects, format nicely
      final names = items.take(2).toList();
      final label = names.length == 1
          ? names.first
          : '${names.first} and ${names.last}';

      if (dir == 'AHEAD') {
        parts.add('$label ahead');
      } else {
        parts.add('$label on your ${dir.toLowerCase()}');
      }
    }

    // Clear buffer after reading
    _buffer.forEach((k, v) => v.clear());

    final text = parts.isEmpty ? 'Path clear' : parts.join(', ');

    setState(() {
      _summaryText = _capitalize(text);
      if (parts.isEmpty) {
        _threatLevel = 0.0;
        _activeDirection = '';
      }
    });

    await _tts.stop();
    await _tts.speak(text);
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  // ── Threat color ──────────────────────────────────────────────────────────

  Color get _threatColor {
    if (_threatLevel > 0.72) return Colors.red;
    if (_threatLevel > 0.38) return Colors.orange;
    return const Color(0xFFC9A227);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final detectModel = Platform.isAndroid ? 'yolo11n.tflite' : 'yolo11n';
    final segModel = Platform.isAndroid ? 'yolo11n-seg.tflite' : 'yolo11n-seg';
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    return GestureDetector(
      onTap: widget.onDismiss,
      child: Stack(
        children: [
          // ── Primary camera: detection model ──────────────────
          SizedBox.expand(
            child: YOLOView(
              key: const ValueKey('scan_detect_yolo'),
              modelPath: detectModel,
              task: YOLOTask.detect,
              confidenceThreshold: 0.35,
              showOverlays: true,
              onResult: _handleDetectResults,
            ),
          ),

          // ── Background: segmentation model (1×1, feeds results only) ──
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: YOLOView(
              key: const ValueKey('scan_seg_yolo'),
              modelPath: segModel,
              task: YOLOTask.segment,
              confidenceThreshold: 0.35,
              showOverlays: false,
              onResult: _handleSegResults,
            ),
          ),

          // ── Threat border pulse ───────────────────────────────
          if (_threatLevel > 0.45)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _threatColor.withOpacity(0.55 * _threatLevel),
                      width: 5,
                    ),
                  ),
                ),
              ),
            ),

          // ── Top bar ───────────────────────────────────────────
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
                    child: const Icon(Icons.radar, color: Color(0xFFC9A227), size: 18),
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
                        'Summarizes every 4 seconds',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: widget.onDismiss,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

          // ── Bottom HUD ────────────────────────────────────────
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
                  // Direction arrows (real-time, based on closest live threat)
                  _DirectionRow(
                    activeDirection: _activeDirection,
                    color: _threatColor,
                  ),
                  const SizedBox(height: 16),

                  // Last spoken summary
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _summaryText,
                      key: ValueKey(_summaryText),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _summaryText == 'Path clear' || _summaryText == 'Scanning environment…'
                            ? Colors.white70
                            : Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        height: 1.35,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Timer hint
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

// ── Direction indicator ───────────────────────────────────────────────────────

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
      width: active ? 60 : 48,
      height: active ? 60 : 48,
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
        size: active ? 28 : 22,
      ),
    );
  }
}
