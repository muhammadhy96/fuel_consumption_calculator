import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the OBD poll loop alive while the screen is off / app backgrounded.
///
/// Android throttles — and eventually kills — background processes, which
/// silently stops the Bluetooth poll loop mid-drive. Promoting the app to a
/// foreground service with a `connectedDevice` type keeps the loop scheduled.
///
/// No-op on every platform except Android. No method here ever throws: if the
/// platform channel is missing or the service refuses to start, the app must
/// keep running with in-app-only tracking.
class TripForegroundService {
  static const MethodChannel _channel =
      MethodChannel('dev.muham.fueltriptracker/trip_service');

  /// Returns true if the service is (now) running. Never throws.
  static Future<bool> start({required String profileName}) async {
    if (!Platform.isAndroid) return false;
    try {
      final started = await _channel.invokeMethod<bool>(
        'startTripService',
        <String, dynamic>{'profileName': profileName},
      );
      return started ?? false;
    } catch (err) {
      if (kDebugMode) {
        debugPrint('TripForegroundService.start failed: $err');
      }
      return false;
    }
  }

  /// Never throws.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopTripService');
    } catch (err) {
      if (kDebugMode) {
        debugPrint('TripForegroundService.stop failed: $err');
      }
    }
  }
}
