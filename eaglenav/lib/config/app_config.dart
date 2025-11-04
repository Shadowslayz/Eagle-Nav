// lib/config.dart
// app configuration for Valhalla server URLs
import 'dart:io' show Platform;

class AppConfig {
  // Set this true if running on a real phone/tablet hitting your Mac over Wi-Fi.
  static const bool useLanIp = false;
  static const String lanBase = 'http://192.168.1.123:8002'; // <- your Mac's IP

  static String get valhallaBaseUrl {
    if (Platform.isAndroid) return 'http://10.0.2.2:8002';
    //if (Platform.isAndroid) return 'http://localhost:8002';
    return 'http://localhost:8002'; // iOS Simulator / macOS
  }
}
