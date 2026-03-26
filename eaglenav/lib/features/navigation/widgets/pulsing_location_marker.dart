import 'dart:math' as math;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';

/// A pulsing location marker with an optional compass heading cone.
///
/// Usage — static (no compass):
///   PulsingLocationMarker()
///
/// Usage — with live compass:
///   PulsingLocationMarker.withCompass()
///
/// Usage — with a known heading (e.g. from CompassService):
///   PulsingLocationMarker(heading: 45.0)
class PulsingLocationMarker extends StatefulWidget {
  final double size;
  final Color dotColor;
  final Color pulseColor;

  /// If non-null, draws a heading cone rotated to this bearing (0–360°).
  /// Use [PulsingLocationMarker.withCompass] to subscribe to the device
  /// compass automatically instead of managing the value yourself.
  final double? heading;

  const PulsingLocationMarker({
    super.key,
    this.size = 20.0,
    this.dotColor = Colors.blue,
    this.pulseColor = Colors.blue,
    this.heading,
  });

  /// Convenience constructor — subscribes to FlutterCompass internally.
  /// No heading management needed in the parent widget.
  static Widget withCompass({
    double size = 20.0,
    Color dotColor = Colors.blue,
    Color pulseColor = Colors.blue,
  }) {
    return _CompassDrivenMarker(
      size: size,
      dotColor: dotColor,
      pulseColor: pulseColor,
    );
  }

  @override
  State<PulsingLocationMarker> createState() => _PulsingLocationMarkerState();
}

// ─── Compass-driven wrapper ───────────────────────────────────────────────────
// Subscribes to FlutterCompass and rebuilds PulsingLocationMarker on heading change.

class _CompassDrivenMarker extends StatefulWidget {
  final double size;
  final Color dotColor;
  final Color pulseColor;

  const _CompassDrivenMarker({
    required this.size,
    required this.dotColor,
    required this.pulseColor,
  });

  @override
  State<_CompassDrivenMarker> createState() => _CompassDrivenMarkerState();
}

class _CompassDrivenMarkerState extends State<_CompassDrivenMarker> {
  double _heading = 0;

  @override
  void initState() {
    super.initState();
    FlutterCompass.events?.listen((CompassEvent event) {
      final h = event.heading;
      if (h == null || !mounted) return;
      setState(() => _heading = (h + 360) % 360);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PulsingLocationMarker(
      size: widget.size,
      dotColor: widget.dotColor,
      pulseColor: widget.pulseColor,
      heading: _heading,
    );
  }
}

// ─── Main marker ─────────────────────────────────────────────────────────────

class _PulsingLocationMarkerState extends State<PulsingLocationMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _scaleAnimation = Tween<double>(
      begin: 0.5,
      end: 2.5,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _opacityAnimation = Tween<double>(
      begin: 0.6,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // ── Heading cone (behind everything else) ──────
            if (widget.heading != null)
              Transform.rotate(
                // Flutter's rotation is clockwise from top (north = 0),
                // which matches compass bearings directly.
                angle: widget.heading! * math.pi / 180,
                child: CustomPaint(
                  size: Size(widget.size * 4, widget.size * 4),
                  painter: _HeadingConePainter(color: widget.dotColor),
                ),
              ),

            // ── Pulsing outer circle ────────────────────────
            Container(
              width: widget.size * _scaleAnimation.value,
              height: widget.size * _scaleAnimation.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.pulseColor.withOpacity(
                  _opacityAnimation.value * 0.4,
                ),
              ),
            ),

            // ── Static outer ring ───────────────────────────
            Container(
              width: widget.size * 1.8,
              height: widget.size * 1.8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.dotColor.withOpacity(0.15),
              ),
            ),

            // ── Inner white ring ────────────────────────────
            Container(
              width: widget.size * 1.1,
              height: widget.size * 1.1,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),

            // ── Blue dot in center ──────────────────────────
            Container(
              width: widget.size * 0.7,
              height: widget.size * 0.7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.dotColor,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Heading cone painter ─────────────────────────────────────────────────────
// Draws a soft teardrop arc pointing upward (north).
// Transform.rotate on the parent handles the actual bearing rotation.

class _HeadingConePainter extends CustomPainter {
  final Color color;

  const _HeadingConePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Cone points upward from center — 40° wide, fades out at the tip
    const halfAngle = 20.0 * math.pi / 180; // 40° total spread
    final radius = size.height * 0.46;

    final path = Path()
      ..moveTo(cx, cy)
      ..lineTo(
        cx + radius * math.sin(-halfAngle),
        cy - radius * math.cos(-halfAngle),
      )
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        -math.pi / 2 - halfAngle,
        halfAngle * 2,
        false,
      )
      ..close();

    // Gradient: opaque at center, transparent at tip
    final gradient = RadialGradient(
      center: Alignment.center,
      radius: 0.5,
      colors: [color.withOpacity(0.55), color.withOpacity(0.0)],
      stops: const [0.0, 1.0],
    );

    final paint = Paint()
      ..shader = gradient.createShader(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      )
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HeadingConePainter old) => old.color != color;
}
