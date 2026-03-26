import 'dart:io';

class AppConfig {
  // Cloud server - runs 24/7, works from anywhere including physical devices
  static const String _cloudServerIp = '136.117.68.104';

  static const String _localNetworkIp =
      //'100.101.125.66';
      '192.168.1.248'; // put your local IP address here
  static const bool _isPhysicalDevice = bool.fromEnvironment(
    'PHYSICAL_DEVICE',
    defaultValue: false,
  );

  static String get valhallaBaseUrl {
    /* if (_isPhysicalDevice) {
      return 'http://$_localNetworkIp:8002';
    }
    if (Platform.isAndroid) {
      return 'http://10.0.2.2:8002';
    }
    if (Platform.isIOS) {
      return 'http://localhost:8002';
    } */
    //return 'http://10.0.2.2:8002';
    return 'http://$_cloudServerIp:8002';
  }
}
