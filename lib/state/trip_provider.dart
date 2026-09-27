import 'dart:async';

import 'package:flutter/material.dart';

import '../core/services/file_service.dart';
import '../core/services/storage_service.dart';
import '../core/utils/trip_integrator.dart';
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

  /// How often the provisional trip record is refreshed while recording.
  static const int _provisionalSaveIntervalSeconds = 30;

  final FileService _fileService;
  final StorageService _storage;

  final Map<String, List<Trip>> _tripsByProfile = {};
  final List<TripSample> _samples = [];
  final TripIntegrator _totals = TripIntegrator();

  CarProfile? _activeProfile;
  bool _running = false;
  int _elapsedSeconds = 0;
  Timer? _timer;
  DateTime? _startTime;
  String? _tripId;
  Trip? _lastTrip;

  TripCsvWriter? _csvWriter;
  Future<TripCsvWriter?>? _writerFuture;
  int _tripToken = 0;

  /// Samples evicted from the front of [_samples] during the running trip.
  int _droppedSamples = 0;

  /// Samples already handed to the streaming writer, counted from the start of
  /// the trip (so it stays comparable across evictions).
  int _writtenSamples = 0;

  bool get running => _running;
  int get elapsedSeconds => _elapsedSeconds;
  Trip? get lastTrip => _lastTrip;
  List<TripSample> get samples => List.unmodifiable(_samples);

  /// Profile the running trip is recorded against, or null when idle.
  String? get activeProfileId => _running ? _activeProfile?.id : null;

  /// Running totals of the current trip. These are the exact numbers
  /// [stopTrip] saves, so the live dashboard reads them too.
  double get totalFuelMl => _totals.fuelMl;
  double get distanceKm => _totals.distanceKm;

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
    final trips = <Trip>[];
    for (final trip in stored) {
      if (!trip.inProgress) {
        trips.add(trip);
      } else if (!(_running && trip.id == _tripId)) {
        final recovered = await _recoverTrip(trip);
        if (recovered != null) trips.add(recovered);
      }
    }
    _tripsByProfile.clear();
    final allTrips = <Trip>[];
    for (final trip in trips) {
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
    final start = DateTime.now();
    _startTime = start;
    _tripId = 'trip-${start.millisecondsSinceEpoch}';
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds += 1;
      if (_elapsedSeconds % _provisionalSaveIntervalSeconds == 0) {
        _saveProvisional();
      }
      notifyListeners();
    });
    // Fire-and-forget: samples recorded before the file is open are buffered in
    // [_samples] and flushed as soon as the writer resolves.
    _writerFuture = _openWriter(profile.id, _tripToken);
    _saveProvisional();
    notifyListeners();
  }

  void addSample(TripSample sample) {
    if (!_running) return;
    _samples.add(sample);
    _totals.add(sample);
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
    final duration = _currentDurationSeconds();

    // Resolve the CSV path before [_samples] is cleared, so the bulk fallback
    // still has the data if the streaming writer failed.
    final csvPath = await _finalizeCsv(profileId);

    // Same id as the provisional record, so saving replaces it.
    final trip = _buildTrip(
      id: _tripId ?? 'trip-${endTime.millisecondsSinceEpoch}',
      profileId: profileId,
      startTime: _startTime ?? endTime,
      endTime: endTime,
      durationSeconds: duration,
      fuelMl: _totals.fuelMl,
      distanceKm: _totals.distanceKm,
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
    _tripId = null;
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

  /// Hands this trip's CSV to the system share sheet.
  ///
  /// [profileName] only shapes the exported filename; the data is whatever was
  /// streamed to disk while the trip ran.
  Future<TripExportResult> shareTrip(
    Trip trip,
    String profileName, {
    Rect? sharePositionOrigin,
  }) {
    return _fileService.shareTripCsv(
      trip.dataFilePath,
      exportName: FileService.exportFileName(profileName, trip.startTime),
      subject: '$profileName trip — ${trip.startTime.toLocal()}',
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  /// Saves a copy of this trip's CSV wherever the driver picks.
  Future<TripExportResult> saveTripCopy(Trip trip, String profileName) {
    return _fileService.saveTripCsvCopy(
      trip.dataFilePath,
      exportName: FileService.exportFileName(profileName, trip.startTime),
    );
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
    _saveProvisional();
    return writer;
  }

  int _currentDurationSeconds() =>
      _samples.isNotEmpty ? _samples.last.timeSeconds.round() : _elapsedSeconds;

  static Trip _buildTrip({
    required String id,
    required String profileId,
    required DateTime startTime,
    required DateTime endTime,
    required int durationSeconds,
    required double fuelMl,
    required double distanceKm,
    String? dataFilePath,
    bool inProgress = false,
  }) {
    return Trip(
      id: id,
      profileId: profileId,
      startTime: startTime,
      endTime: endTime,
      durationSeconds: durationSeconds,
      totalFuelMl: fuelMl,
      avgFuelMlPerSec: durationSeconds > 0 ? fuelMl / durationSeconds : 0.0,
      distanceKm: distanceKm,
      avgConsumptionLPer100Km:
          distanceKm > 0 ? (fuelMl / 1000) / distanceKm * 100 : 0.0,
      dataFilePath: dataFilePath,
      inProgress: inProgress,
    );
  }

  /// Keeps a provisional record in storage while recording, so a trip whose
  /// app is killed before STOP can be recovered on the next launch.
  void _saveProvisional() {
    final profile = _activeProfile;
    final id = _tripId;
    final start = _startTime;
    if (!_running || profile == null || id == null || start == null) return;
    final duration = _currentDurationSeconds();
    unawaited(_persistQuietly(_buildTrip(
      id: id,
      profileId: profile.id,
      startTime: start,
      endTime: start.add(Duration(seconds: duration)),
      durationSeconds: duration,
      fuelMl: _totals.fuelMl,
      distanceKm: _totals.distanceKm,
      dataFilePath: _csvWriter?.path,
      inProgress: true,
    )));
  }

  Future<void> _persistQuietly(Trip trip) async {
    try {
      await _storage.saveTrip(trip);
    } catch (err) {
      debugPrint('Failed to save provisional trip: $err');
    }
  }

  /// Finalises a trip the app never got to stop, from whatever reached its
  /// CSV. Returns null (and drops the record) when nothing was recorded.
  Future<Trip?> _recoverTrip(Trip provisional) async {
    final path = provisional.dataFilePath;
    var samples = const <TripSample>[];
    if (path != null) {
      try {
        samples = await _fileService.loadTripSamples(path);
      } catch (err) {
        debugPrint('Failed to read CSV of interrupted trip: $err');
      }
    }
    final Trip recovered;
    if (samples.isNotEmpty) {
      final totals = TripIntegrator()..addAll(samples);
      final duration = samples.last.timeSeconds.round();
      recovered = _buildTrip(
        id: provisional.id,
        profileId: provisional.profileId,
        startTime: provisional.startTime,
        endTime: provisional.startTime.add(Duration(seconds: duration)),
        durationSeconds: duration,
        fuelMl: totals.fuelMl,
        distanceKm: totals.distanceKm,
        dataFilePath: path,
      );
    } else if (provisional.totalFuelMl > 0 || provisional.distanceKm > 0) {
      recovered = _buildTrip(
        id: provisional.id,
        profileId: provisional.profileId,
        startTime: provisional.startTime,
        endTime: provisional.endTime,
        durationSeconds: provisional.durationSeconds,
        fuelMl: provisional.totalFuelMl,
        distanceKm: provisional.distanceKm,
        dataFilePath: path,
      );
    } else {
      try {
        await _storage.deleteTrip(provisional.id);
      } catch (err) {
        debugPrint('Failed to drop empty interrupted trip: $err');
      }
      return null;
    }
    try {
      await _storage.saveTrip(recovered);
    } catch (err) {
      debugPrint('Failed to save recovered trip: $err');
    }
    return recovered;
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

  /// Trims the oldest samples once the in-memory cap is exceeded. Totals are
  /// accumulated as samples arrive, so eviction cannot change them.
  void _evictOldSamplesIfNeeded() {
    if (_samples.length < maxInMemorySamples + _evictionBatch) return;
    final removeCount = _samples.length - maxInMemorySamples;
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
    _totals.reset();
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
}
