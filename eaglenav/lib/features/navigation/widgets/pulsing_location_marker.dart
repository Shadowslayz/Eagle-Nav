import 'package:flutter/material.dart';

/// A pulsing location marker similar to Google Maps
class PulsingLocationMarker extends StatefulWidget {
  final double size;
  final Color dotColor;
  final Color pulseColor;

  const PulsingLocationMarker({
    super.key,
    this.size = 20.0,
    this.dotColor = Colors.blue,
    this.pulseColor = Colors.blue,
  });

  @override
  State<PulsingLocationMarker> createState() => _PulsingLocationMarkerState();
}

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
            // Pulsing outer circle
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
            // Static outer ring
            Container(
              width: widget.size * 1.8,
              height: widget.size * 1.8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.dotColor.withOpacity(0.15),
              ),
            ),
            // Inner white ring
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
            // Blue dot in center
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
