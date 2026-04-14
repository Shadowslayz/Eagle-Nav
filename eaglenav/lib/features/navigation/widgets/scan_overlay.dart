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

  String _statusText = 'Scanning…';
  String _direction = ''; // 'LEFT', 'AHEAD', 'RIGHT'
  String _proximityLabel = '';
  double _threatLevel = 0.0; // 0.0–1.0
  bool _isClear = true;

  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _clearTimer;

  // Classes that aren't obstacles worth announcing while walking
  static const Set<String> _ignored = {
    'ceiling', 'floor', 'sky', 'road', 'sidewalk', 'ground', 'pavement',
  };

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.52);
    await _tts.setVolume(1.0);
  }

  @override
  void dispose() {
    _tts.stop();
    _clearTimer?.cancel();
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

  // Returns 0 (far/ignore), 1 (heads-up), 2 (warning), 3 (stop)
  int _urgency(double area) {
    if (area > 0.28) return 3;
    if (area > 0.12) return 2;
    if (area > 0.04) return 1;
    return 0;
  }

  String _proximityText(double area) {
    if (area > 0.28) return 'STOP';
    if (area > 0.12) return 'CLOSE';
    return '';
  }

  bool _cooldownOk({required int ms}) =>
      DateTime.now().difference(_lastSpoken).inMilliseconds >= ms;

  // ── Result handler ────────────────────────────────────────────────────────

  Future<void> _handleResults(List<YOLOResult> results) async {
    _clearTimer?.cancel();

    final relevant = results.where((r) =>
        r.className.isNotEmpty &&
        !_ignored.contains(r.className.toLowerCase())).toList();

    if (relevant.isEmpty) {
      // Schedule "path clear" after 3 s of nothing
      _clearTimer = Timer(const Duration(seconds: 3), () async {
        if (!mounted) return;
        if (!_cooldownOk(ms: 4000)) return;
        _lastSpoken = DateTime.now();
        setState(() {
          _statusText = 'Path clear';
          _direction = '';
          _proximityLabel = '';
          _threatLevel = 0.0;
          _isClear = true;
        });
        await _tts.stop();
        await _tts.speak('Path clear');
      });
      return;
    }

    // Pick the closest object (largest normalizedBox area)
    relevant.sort((a, b) =>
        _area(b.normalizedBox).compareTo(_area(a.normalizedBox)));
    final top = relevant.first;

    final area = _area(top.normalizedBox);
    final urgency = _urgency(area);
    if (urgency == 0) return; // too far, not worth announcing

    final dir = _directionFrom(top.normalizedBox);
    final prox = _proximityText(area);
    final name = top.className;

    setState(() {
      _statusText = _capitalize(name);
      _direction = dir;
      _proximityLabel = prox;
      _threatLevel = (area / 0.35).clamp(0.0, 1.0);
      _isClear = false;
    });

    // Haptics scaled to urgency
    switch (urgency) {
      case 3:
        HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 120));
        HapticFeedback.heavyImpact();
        break;
      case 2:
        HapticFeedback.mediumImpact();
        break;
      default:
        HapticFeedback.lightImpact();
    }

    // TTS with urgency-based cooldown
    final cooldownMs = urgency >= 3 ? 1200 : urgency == 2 ? 2200 : 3500;
    if (!_cooldownOk(ms: cooldownMs)) return;
    _lastSpoken = DateTime.now();

    final dirPhrase = dir == 'AHEAD' ? 'ahead' : 'on your ${dir.toLowerCase()}';
    final speech = urgency >= 3
        ? '$name $dirPhrase — stop'
        : prox.isNotEmpty
            ? '$name $dirPhrase, $prox'
            : '$name $dirPhrase';

    await _tts.stop();
    await _tts.speak(speech);
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
    final modelPath = Platform.isAndroid ? 'yolo11n.tflite' : 'yolo11n';
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    return GestureDetector(
      onTap: widget.onDismiss,
      child: Stack(
        children: [
          // ── Camera feed ──────────────────────────────────────────
          SizedBox.expand(
            child: YOLOView(
              key: const ValueKey('scan_overlay_yolo'),
              modelPath: modelPath,
              task: YOLOTask.detect,
              confidenceThreshold: 0.35,
              showOverlays: true,
              onResult: _handleResults,
            ),
          ),

          // ── Threat border pulse ───────────────────────────────────
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

          // ── Top bar ───────────────────────────────────────────────
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
                  const Text(
                    'Obstacle Scan',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
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

          // ── Bottom HUD ────────────────────────────────────────────
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
                  // Direction arrows
                  _DirectionRow(activeDirection: _direction, color: _threatColor),
                  const SizedBox(height: 16),

                  // Main status
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _statusText,
                      key: ValueKey(_statusText),
                      style: TextStyle(
                        color: _isClear ? Colors.white70 : _threatColor,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  // Proximity badge
                  if (_proximityLabel.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: _threatColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _threatColor.withOpacity(0.5)),
                      ),
                      child: Text(
                        _proximityLabel,
                        style: TextStyle(
                          color: _threatColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Tap anywhere to close',
                    style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12),
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
          label: 'L',
        ),
        const SizedBox(width: 12),
        _Arrow(
          icon: Icons.arrow_upward_rounded,
          active: activeDirection == 'AHEAD',
          color: color,
          label: 'F',
        ),
        const SizedBox(width: 12),
        _Arrow(
          icon: Icons.arrow_forward_rounded,
          active: activeDirection == 'RIGHT',
          color: color,
          label: 'R',
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color color;
  final String label;

  const _Arrow({
    required this.icon,
    required this.active,
    required this.color,
    required this.label,
  });

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
