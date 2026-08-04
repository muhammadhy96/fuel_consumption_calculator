import 'dart:async';

import 'package:flutter/material.dart';

import '../core/services/file_service.dart';
import '../core/services/storage_service.dart';
import '../models/car_profile.dart';
import '../models/trip.dart';
import '../models/trip_sample.dart';

class TripProvider extends ChangeNotifier {
  TripProvider(this._fileService, this._storage);

  /// Upper bound on samples retained in RAM during a trip.
  ///
  /// Every sample is streamed to disk as it arrives, so exceeding this only
  /// trims the oldest part of the in-memory buffer; the CSV still holds the
  /// full trip.
  static const int maxInMemorySamples = 50000;

  /// Samples dropped per eviction pass. Trimming in batches keeps the list
  /// shift amortised O(1) per sample instead of O(n) on every append.
  static const int _evictionBatch = 1000;

  final FileService _fileService;
  final StorageService _storage;

  final Map<String, List<Trip>> _tripsByProfile = {};
  final List<TripSample> _samples = [];

  CarProfile? _activeProfile;
  bool _running = false;
  int _elapsedSeconds = 0;
  Timer? _timer;
  DateTime? _startTime;
  Trip? _lastTrip;

  TripCsvWriter? _csvWriter;
  Future<TripCsvWriter?>? _writerFuture;
  int _tripToken = 0;

  /// Samples evicted from the front of [_samples] during the running trip.
  int _droppedSamples = 0;

  /// Samples already handed to the streaming writer, counted from the start of
  /// the trip (so it stays comparable across evictions).
  int _writtenSamples = 0;

  /// Fuel / distance already integrated out of the evicted samples, so the trip
  /// summary stays exact even when the in-memory buffer has been trimmed.
  double _carriedFuelMl = 0;
  double _carriedDistanceKm = 0;

  bool get running => _running;
  int get elapsedSeconds => _elapsedSeconds;
  Trip? get lastTrip => _lastTrip;
  List<TripSample> get samples => List.unmodifiable(_samples);

  /// Path of the CSV currently being streamed, or null when no trip is running
  /// or the streaming writer could not be opened.
  String? get activeCsvPath => _csvWriter?.path;

  List<Trip> tripsForProfile(String profileId) {
    final trips = _tripsByProfile[profileId] ?? const [];
    return List.unmodifiable(trips);
  }

  bool hasTrips(String profileId) =>
      (_tripsByProfile[profileId]?.isNotEmpty ?? false);

  Future<void> loadTrips() async {
    final stored = await _storage.loadTrips();
    _tripsByProfile
      .clear();
    final allTrips = <Trip>[];
    for (final trip in stored) {
      final list = _tripsByProfile.putIfAbsent(trip.profileId, () => []);
      list.add(trip);
      allTrips.add(trip);
    }
    for (final list in _tripsByProfile.values) {
      list.sort((a, b) => b.startTime.compareTo(a.startTime));
    }
    allTrips.sort((a, b) => b.startTime.compareTo(a.startTime));
    _lastTrip = allTrips.isNotEmpty ? allTrips.first : null;
    notifyListeners();
  }

  void startTrip(CarProfile profile) {
    if (_running) return;
    _activeProfile = profile;
    _running = true;
    _elapsedSeconds = 0;
    _samples.clear();
    _resetSampleAccounting();
    _startTime = DateTime.now();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds += 1;
      notifyListeners();
    });
    // Fire-and-forget: samples recorded before the file is open are buffered in
    // [_samples] and flushed as soon as the writer resolves.
    _writerFuture = _openWriter(profile.id, _tripToken);
    notifyListeners();
  }

  void addSample(TripSample sample) {
    if (!_running) return;
    _samples.add(sample);
    final writer = _csvWriter;
    if (writer != null) {
      writer.addSample(sample);
      _writtenSamples = _droppedSamples + _samples.length;
    }
    _evictOldSamplesIfNeeded();
  }

  Future<Trip?> stopTrip() async {
    if (!_running || _activeProfile == null) return null;
    _timer?.cancel();
    _timer = null;
    _running = false;

    final profileId = _activeProfile!.id;
    final endTime = DateTime.now();
    final duration =
        _samples.isNotEmpty ? _samples.last.timeSeconds.round() : _elapsedSeconds;
    final totalFuel = _integrateFuelMl() + _carriedFuelMl;
    final avgFuel = duration > 0 ? totalFuel / duration : 0.0;
    final distanceKm = _calculateDistanceKm() + _carriedDistanceKm;
    final avgConsumption =
        distanceKm > 0 ? (totalFuel / 1000) / distanceKm * 100 : 0.0;

    // Resolve the CSV path before [_samples] is cleared, so the bulk fallback
    // still has the data if the streaming writer failed.
    final csvPath = await _finalizeCsv(profileId);

    final trip = Trip(
      id: 'trip-${DateTime.now().millisecondsSinceEpoch}',
      profileId: profileId,
      startTime: _startTime ?? endTime,
      endTime: endTime,
      durationSeconds: duration,
      totalFuelMl: totalFuel,
      avgFuelMlPerSec: avgFuel,
      distanceKm: distanceKm,
      avgConsumptionLPer100Km: avgConsumption,
      dataFilePath: csvPath,
    );

    final list = _tripsByProfile.putIfAbsent(profileId, () => []);
    list.insert(0, trip);
    _lastTrip = trip;
    try {
      await _storage.saveTrip(trip);
    } catch (err) {
      debugPrint('Failed to persist trip metadata: $err');
    }

    _activeProfile = null;
    _elapsedSeconds = 0;
    _samples.clear();
    _resetSampleAccounting();
    notifyListeners();
    return trip;
  }

  Future<void> deleteTrip(String profileId, String tripId) async {
    final trips = _tripsByProfile[profileId];
    trips?.removeWhere((trip) => trip.id == tripId);
    if (trips != null && trips.isEmpty) {
      _tripsByProfile.remove(profileId);
    }
    await _storage.deleteTrip(tripId);
    notifyListeners();
  }

  Future<List<TripSample>> loadSamples(String path) {
    return _fileService.loadTripSamples(path);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _discardWriter();
    super.dispose();
  }

  /// Opens the streaming CSV writer in the background.
  ///
  /// Never throws and never rejects; a null result just means the trip falls
  /// back to the bulk save at stop time.
  Future<TripCsvWriter?> _openWriter(String profileId, int token) async {
    TripCsvWriter? writer;
    try {
      writer = await _fileService.openTripWriter(profileId);
    } catch (err) {
      debugPrint('Failed to open trip CSV writer: $err');
      return null;
    }
    if (writer == null) return null;
    if (token != _tripToken) {
      // The trip ended (or another one started) while the file was opening.
      await writer.close();
      return null;
    }
    _csvWriter = writer;
    _flushWriterBacklog();
    return writer;
  }

  /// Writes every buffered sample the writer has not seen yet.
  void _flushWriterBacklog() {
    final writer = _csvWriter;
    if (writer == null) return;
    var start = _writtenSamples - _droppedSamples;
    if (start < 0) start = 0;
    for (var i = start; i < _samples.length; i++) {
      writer.addSample(_samples[i]);
    }
    _writtenSamples = _droppedSamples + _samples.length;
  }

  /// Trims the oldest samples once the in-memory cap is exceeded.
  ///
  /// The dropped segment is folded into [_carriedFuelMl] / [_carriedDistanceKm]
  /// first — including the trapezoid straddling the eviction boundary — so the
  /// trip totals match a full-buffer integration exactly.
  void _evictOldSamplesIfNeeded() {
    if (_samples.length < maxInMemorySamples + _evictionBatch) return;
    final removeCount = _samples.length - maxInMemorySamples;
    for (var i = 1; i <= removeCount; i++) {
      final prev = _samples[i - 1];
      final curr = _samples[i];
      final dt = curr.timeSeconds - prev.timeSeconds;
      if (dt > 0) {
        _carriedFuelMl += ((prev.fuelMlPerSec + curr.fuelMlPerSec) / 2) * dt;
        _carriedDistanceKm +=
            (((prev.speedKph + curr.speedKph) / 2) * dt) / 3600;
      }
    }
    _samples.removeRange(0, removeCount);
    _droppedSamples += removeCount;
  }

  /// Closes the streaming writer and returns the trip CSV path, falling back to
  /// a one-shot bulk write only when streaming was unavailable or failed.
  Future<String?> _finalizeCsv(String profileId) async {
    final pending = _writerFuture;
    _writerFuture = null;
    if (pending != null) {
      try {
        await pending;
      } catch (err) {
        debugPrint('Failed to open trip CSV writer: $err');
      }
    }
    final writer = _csvWriter;
    _csvWriter = null;
    if (writer != null) {
      try {
        final path = await writer.close();
        if (path != null) return path;
      } catch (err) {
        debugPrint('Failed to close trip CSV writer: $err');
      }
    }
    try {
      return await _fileService.saveTripSamples(profileId, List.of(_samples));
    } catch (err) {
      debugPrint('Failed to save trip samples: $err');
      return null;
    }
  }

  void _resetSampleAccounting() {
    _droppedSamples = 0;
    _writtenSamples = 0;
    _carriedFuelMl = 0;
    _carriedDistanceKm = 0;
    _discardWriter();
  }

  /// Detaches any writer still held and closes it in the background. Bumping
  /// the token makes an in-flight [_openWriter] discard its result.
  void _discardWriter() {
    _tripToken += 1;
    final writer = _csvWriter;
    _csvWriter = null;
    _writerFuture = null;
    if (writer != null) {
      unawaited(writer.close());
    }
  }

  double _calculateDistanceKm() {
    if (_samples.length < 2) return 0;
    double distance = 0;
    for (var i = 1; i < _samples.length; i++) {
      final prev = _samples[i - 1];
      final curr = _samples[i];
      final dt = curr.timeSeconds - prev.timeSeconds;
      if (dt > 0) {
        final avgSpeed = (prev.speedKph + curr.speedKph) / 2;
        distance += (avgSpeed * dt) / 3600;
      }
    }
    return distance;
  }

  double _integrateFuelMl() {
    if (_samples.length < 2) return 0;
    double total = 0;
    for (var i = 1; i < _samples.length; i++) {
      final prev = _samples[i - 1];
      final curr = _samples[i];
      final dt = curr.timeSeconds - prev.timeSeconds;
      if (dt > 0) {
        final avgRate = (prev.fuelMlPerSec + curr.fuelMlPerSec) / 2;
        total += avgRate * dt;
      }
    }
    return total;
  }
}
