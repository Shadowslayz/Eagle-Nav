import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'dart:math';

class VisionEngine {
  Interpreter? _detector;
  Interpreter? _depth;
  bool _ready = false;

  Future<void> init() async {
    try {
      _detector = await Interpreter.fromAsset('object_detector.tflite');
      _depth = await Interpreter.fromAsset('depth_estimator.tflite');
      _ready = true;
      print("✅ Models loaded successfully");
    } catch (e) {
      print("⚠️ Model load error: $e");
    }
  }

  bool get isReady => _ready;

  Future<List<Map<String, dynamic>>> processFrame(img.Image frame) async {
    if (!_ready) return [];

    final width = frame.width;
    final height = frame.height;

    // Prepare input for detection model
    // Resize + normalize the frame to model’s input size (usually 320x320)
    final resized = img.copyResize(frame, width: 320, height: 320);
    final input = List.generate(
      1,
      (_) => List.generate(
        320,
        (_) => List.generate(
          320,
          (__) => [0.0, 0.0, 0.0],
        ),
      ),
    );

    // Fill normalized pixel data
    for (int y = 0; y < 320; y++) {
      for (int x = 0; x < 320; x++) {
        final pixel = resized.getPixel(x, y);

        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();

        input[0][y][x][0] = r / 255.0;
        input[0][y][x][1] = g / 255.0;
        input[0][y][x][2] = b / 255.0;
      }
    }

    // Create output tensor (adjust shape if your model metadata differs)
    final outputBoxes = List.filled(1 * 10 * 4, 0.0).reshape([1, 10, 4]);
    final outputScores = List.filled(1 * 10, 0.0).reshape([1, 10]);
    final outputClasses = List.filled(1 * 10, 0.0).reshape([1, 10]);
    final outputCount = List.filled(1, 0.0).reshape([1]);

    final outputs = {
      0: outputBoxes,
      1: outputClasses,
      2: outputScores,
      3: outputCount,
    };

    _detector!.runForMultipleInputs([input], outputs);

    final numDetections = outputCount[0][0].toInt();
    List<Map<String, dynamic>> detections = [];

    for (int i = 0; i < numDetections; i++) {
      final score = outputScores[0][i];
      if (score < 0.4) continue;

      final label = "object"; // Replace with your label map later
      final bbox = outputBoxes[0][i]; // [ymin, xmin, ymax, xmax]
      final x = bbox[1] * width;
      final y = bbox[0] * height;
      final w = (bbox[3] - bbox[1]) * width;
      final h = (bbox[2] - bbox[0]) * height;

      final direction = x + w / 2 < width * 0.33
          ? "left"
          : (x + w / 2 > width * 0.66 ? "right" : "center");

      detections.add({
        "id": i,
        "label": label,
        "confidence": score,
        "bbox": [x, y, w, h],
        "distance_m": Random().nextDouble() * 5,
        "direction": direction,
      });
    }

    return detections;
  }
}
