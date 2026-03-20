import 'dart:io';

class AppConfig {
  static const String _localNetworkIp = ''; // put your local IP address here
  static const bool _isPhysicalDevice = bool.fromEnvironment(
    'PHYSICAL_DEVICE',
    defaultValue: false,
  );

  static String get valhallaBaseUrl {
    if (_isPhysicalDevice) {
      return 'http://$_localNetworkIp:8002';
    }
    if (Platform.isAndroid) {
      return 'http://10.0.2.2:8002';
    }
    if (Platform.isIOS) {
      return 'http://localhost:8002';
    }
    return 'http://10.0.2.2:8002';
  }
}
