import '../../models/trip_sample.dart';
import 'can_monitor.dart';

/// Trapezoidal fuel and distance totals over consecutive trip samples.
///
/// The live dashboard, the saved trip and crash recovery all integrate through
/// this one class, so the numbers on screen and in history cannot disagree.
class TripIntegrator {
  /// Longer gaps between samples (a reconnect, a stalled adapter) are not
  /// interpolated: nothing is known about what happened inside them.
  static const double maxGapSeconds = 10;

  double fuelMl = 0;

  /// From [TripSample.distanceSpeedKph]: GPS where there was a fix.
  double distanceKm = 0;

  /// From the OBD speed alone, for comparison with [distanceKm].
  double obdDistanceKm = 0;

  /// Whether the latest sample's distance came from GPS.
  bool lastFromGps = false;
  TripSample? _last;

  /// CAN fuel reads further apart than this are not bridged.
  static const double maxCanGapSeconds = 5;

  /// Integral of the raw ECU fuel count over time (count x s), between
  /// consecutive samples that carry a CAN read.
  double canRawSeconds = 0;

  /// Time covered by [canRawSeconds], and the app's own fuel over exactly
  /// that time, so the two can be compared like for like.
  double canCoveredSeconds = 0;
  double appFuelMlOverCan = 0;

  double? _lastCanTime;
  int? _lastCanRaw;
  double _appFuelMlAtLastCan = 0;

  /// Frames counted and listening time over the trip's CAN reads.
  int canPeriodFrames = 0;
  int canPeriodListenMs = 0;

  /// The [CanFuelSignal] message period the reads measured, ms; null until
  /// 20 frames were counted (trips recorded before it was logged have none).
  double? get canFramePeriodMs =>
      canPeriodFrames < 20 ? null : canPeriodListenMs / canPeriodFrames;

  /// The ECU's fuel over the trip at the [CanFuelSignal] scale.
  double get canFuelMl => canRawSeconds * CanFuelSignal.mlPerSecPerCount;

  void add(TripSample sample) {
    final last = _last;
    _last = sample;
    lastFromGps = sample.gpsSpeedKph != null;
    if (last != null) {
      final dt = sample.timeSeconds - last.timeSeconds;
      if (dt > 0 && dt <= maxGapSeconds) {
        fuelMl += ((last.fuelMlPerSec + sample.fuelMlPerSec) / 2) * dt;
        distanceKm +=
            (((last.distanceSpeedKph + sample.distanceSpeedKph) / 2) * dt) /
                3600;
        obdDistanceKm += (((last.speedKph + sample.speedKph) / 2) * dt) / 3600;
      }
    }
    _addCan(sample);
  }

  void _addCan(TripSample sample) {
    final raw = sample.canFuelRaw;
    if (raw == null) return;
    final frames = sample.canFrameCount;
    final listenMs = sample.canListenMs;
    if (frames != null && frames > 0 && listenMs != null && listenMs > 0) {
      canPeriodFrames += frames;
      canPeriodListenMs += listenMs;
    }
    final lastTime = _lastCanTime;
    final lastRaw = _lastCanRaw;
    if (lastTime != null && lastRaw != null) {
      final dt = sample.timeSeconds - lastTime;
      if (dt > 0 && dt <= maxCanGapSeconds) {
        canRawSeconds += (lastRaw + raw) / 2 * dt;
        canCoveredSeconds += dt;
        appFuelMlOverCan += fuelMl - _appFuelMlAtLastCan;
      }
    }
    _lastCanTime = sample.timeSeconds;
    _lastCanRaw = raw;
    _appFuelMlAtLastCan = fuelMl;
  }

  void addAll(Iterable<TripSample> samples) {
    for (final sample in samples) {
      add(sample);
    }
  }

  void reset() {
    fuelMl = 0;
    distanceKm = 0;
    obdDistanceKm = 0;
    lastFromGps = false;
    _last = null;
    canRawSeconds = 0;
    canCoveredSeconds = 0;
    appFuelMlOverCan = 0;
    _lastCanTime = null;
    _lastCanRaw = null;
    _appFuelMlAtLastCan = 0;
    canPeriodFrames = 0;
    canPeriodListenMs = 0;
  }
}
