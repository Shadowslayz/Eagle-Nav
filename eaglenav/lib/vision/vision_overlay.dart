import 'package:flutter/material.dart';

class VisionOverlay extends StatelessWidget {
  final List<Map<String, dynamic>> detections;
  const VisionOverlay({super.key, required this.detections});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _OverlayPainter(detections));
  }
}

class _OverlayPainter extends CustomPainter {
  final List<Map<String, dynamic>> dets;
  _OverlayPainter(this.dets);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    for (final d in dets) {
      final bbox = d['bbox'] as List;
      final rect = Rect.fromLTWH(
        bbox[0].toDouble(),
        bbox[1].toDouble(),
        bbox[2].toDouble(),
        bbox[3].toDouble(),
      );

      // color based on label
      paint.color = d['label'] == "unknown" ? Colors.yellow : Colors.green;
      canvas.drawRect(rect, paint);

      final text = "${d['label']} (${d['distance_m']}m)";
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(rect.left, rect.top - 20));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
