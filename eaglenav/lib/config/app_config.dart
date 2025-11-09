import 'dart:io';

class AppConfig {
  static String get valhallaBaseUrl {
    if (Platform.isAndroid) {
      // If Android emulator → 10.0.2.2 is always the HOST MACHINE
      return 'http://10.0.2.2:8002';
    }
    if (Platform.isIOS) {
      // iOS Simulator uses localhost directly
      return 'http://localhost:8002';
    }

    return 'http://10.0.2.2:8002';
  }
}
