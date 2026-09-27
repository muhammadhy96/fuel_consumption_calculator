import '../../models/trip_sample.dart';

/// Trapezoidal fuel and distance totals over consecutive trip samples.
///
/// The live dashboard, the saved trip and crash recovery all integrate through
/// this one class, so the numbers on screen and in history cannot disagree.
class TripIntegrator {
  /// Longer gaps between samples (a reconnect, a stalled adapter) are not
  /// interpolated: nothing is known about what happened inside them.
  static const double maxGapSeconds = 10;

  double fuelMl = 0;
  double distanceKm = 0;
  TripSample? _last;

  void add(TripSample sample) {
    final last = _last;
    _last = sample;
    if (last == null) return;
    final dt = sample.timeSeconds - last.timeSeconds;
    if (dt <= 0 || dt > maxGapSeconds) return;
    fuelMl += ((last.fuelMlPerSec + sample.fuelMlPerSec) / 2) * dt;
    distanceKm += (((last.speedKph + sample.speedKph) / 2) * dt) / 3600;
  }

  void addAll(Iterable<TripSample> samples) {
    for (final sample in samples) {
      add(sample);
    }
  }

  void reset() {
    fuelMl = 0;
    distanceKm = 0;
    _last = null;
  }
}
