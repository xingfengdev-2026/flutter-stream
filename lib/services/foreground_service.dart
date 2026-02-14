import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ForegroundService {
  static const _channel = MethodChannel('com.golive/foreground_service');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod('startService');
      debugPrint('[GoLive] Foreground service started');
    } catch (e) {
      debugPrint('[GoLive] Failed to start foreground service: $e');
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopService');
      debugPrint('[GoLive] Foreground service stopped');
    } catch (e) {
      debugPrint('[GoLive] Failed to stop foreground service: $e');
    }
  }
}
