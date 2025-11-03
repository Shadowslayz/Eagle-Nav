import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import '../vision/vision_engine.dart';
import '../vision/vision_overlay.dart';

class ARTestScreen extends StatefulWidget {
  const ARTestScreen({super.key});
  @override
  State<ARTestScreen> createState() => _ARTestScreenState();
}

class _ARTestScreenState extends State<ARTestScreen> {
  CameraController? _controller;
  bool _isCameraReady = false;
  bool _isProcessing = false;
  VisionEngine vision = VisionEngine();
  List<Map<String, dynamic>> detections = [];

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final firstCamera = cameras.first;

      _controller = CameraController(
        firstCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();
      await vision.init();

      if (mounted) setState(() => _isCameraReady = true);

      // Start vision loop
      _controller!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint("Camera init error: $e");
    }
  }

  int _frameCount = 0;

  Future<void> _processCameraImage(CameraImage image) async {
    _frameCount++;
    if (_frameCount % 3 != 0 || _isProcessing) return; // skip 2 of every 3 frames
    _isProcessing = true;

    try {
      final imgRGB = _convertYUV420toImageColor(image);
      final result = await vision.processFrame(imgRGB);
      if (mounted) setState(() => detections = result);
    } finally {
      _isProcessing = false;
    }
  }




  /// Converts YUV420 camera image to RGB image.Image
  img.Image _convertYUV420toImageColor(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel!;
    final imgOut = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
        final yp = image.planes[0].bytes[y * image.planes[0].bytesPerRow + x];
        final up = image.planes[1].bytes[uvIndex];
        final vp = image.planes[2].bytes[uvIndex];

        int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
        int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
            .round()
            .clamp(0, 255);
        int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

        imgOut.setPixelRgb(x, y, r, g, b);
      }
    }
    return imgOut;
  }


  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isCameraReady
          ? Stack(
              fit: StackFit.expand,
              children: [
                // Live camera feed
                CameraPreview(_controller!),
                // Transparent overlay showing detections
                IgnorePointer(child: VisionOverlay(detections: detections)),
                // Display live data bottom panel
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    height: 140,
                    color: Colors.black.withOpacity(0.6),
                    padding: const EdgeInsets.all(10),
                    child: ListView(
                      children: detections.map((d) {
                        return Text(
                          "🟢 ${d['label']} - ${d['distance_m']}m (${d['direction']})",
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            )
          : const Center(
              child: CircularProgressIndicator(color: Colors.amber),
            ),
    );
  }
}
