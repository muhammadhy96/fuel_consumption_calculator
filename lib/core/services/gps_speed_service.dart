import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Why [GpsSpeedService.start] could or could not stream fixes.
enum GpsStatus {
  running,

  /// Location is switched off on the phone.
  serviceOff,
  permissionDenied,

  /// Only approximate location was granted, which carries no usable speed.
  approximateOnly,

  /// No location provider on this platform, or the plugin failed.
  unavailable,
}

/// Ground speed from the phone's GPS, which the trip distance is integrated
/// from in place of the OBD wheel speed when there is a fix.
///
/// Nothing here ever throws: without a fix, permission or precise location
/// [speedKph] is simply null and the trip falls back to the OBD speed.
class GpsSpeedService {
  /// A fix older than this no longer describes the car (tunnel, garage).
  static const Duration maxFixAge = Duration(seconds: 3);

  /// Fixes whose speed is less certain than this (1 σ, m/s) are ignored.
  static const double maxSpeedAccuracyMps = 2.5;

  StreamSubscription<Position>? _subscription;
  Position? _last;

  /// Monotonic age of [_last]: the fix's own timestamp comes from the GNSS
  /// clock and can disagree with the phone's.
  final Stopwatch _sinceFix = Stopwatch();

  bool get isRunning => _subscription != null;

  /// Asks for location permission if needed, then starts streaming fixes.
  Future<GpsStatus> start() async {
    if (_subscription != null) return GpsStatus.running;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return GpsStatus.serviceOff;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return GpsStatus.permissionDenied;
      }
      if (await Geolocator.getLocationAccuracy() ==
          LocationAccuracyStatus.reduced) {
        // Android offers the upgrade to precise when asked again.
        await Geolocator.requestPermission();
        if (await Geolocator.getLocationAccuracy() ==
            LocationAccuracyStatus.reduced) {
          return GpsStatus.approximateOnly;
        }
      }
      _subscription = Geolocator.getPositionStream(
        locationSettings: _settings(),
      ).listen(
        _onPosition,
        onError: (Object err) {
          if (kDebugMode) debugPrint('[GpsSpeedService] stream error: $err');
        },
      );
      return GpsStatus.running;
    } catch (err) {
      if (kDebugMode) debugPrint('[GpsSpeedService] start failed: $err');
      return GpsStatus.unavailable;
    }
  }

  void stop() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _last = null;
    _sinceFix
      ..stop()
      ..reset();
  }

  /// Current ground speed, or null when there is no fresh, usable fix.
  double? get speedKph {
    final fix = _freshFix;
    return fix == null ? null : fix.speed * 3.6;
  }

  /// 1-σ accuracy of [speedKph], or null when the phone does not report it.
  double? get speedAccuracyKph {
    final fix = _freshFix;
    if (fix == null || !fix.hasSpeedAccuracy) return null;
    return fix.speedAccuracy * 3.6;
  }

  Position? get _freshFix {
    final fix = _last;
    if (fix == null || _sinceFix.elapsed > maxFixAge) return null;
    return fix;
  }

  void _onPosition(Position position) {
    final speed = position.speed;
    if (!position.hasSpeed || !speed.isFinite || speed < 0) return;
    if (position.hasSpeedAccuracy &&
        position.speedAccuracy > maxSpeedAccuracyMps) {
      return;
    }
    _last = position;
    _sinceFix
      ..reset()
      ..start();
  }

  /// One fix a second, unfiltered by distance so a standing car still reports.
  static LocationSettings _settings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
      );
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        // Background location would need the location background mode.
        allowBackgroundLocationUpdates: false,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
  }
}
