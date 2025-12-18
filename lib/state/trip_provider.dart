import 'dart:async';

import 'package:flutter/material.dart';

import '../core/services/file_service.dart';
import '../core/services/storage_service.dart';
import '../models/car_profile.dart';
import '../models/trip.dart';
import '../models/trip_sample.dart';

class TripProvider extends ChangeNotifier {
  TripProvider(this._fileService, this._storage);

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

  bool get running => _running;
  int get elapsedSeconds => _elapsedSeconds;
  Trip? get lastTrip => _lastTrip;
  List<TripSample> get samples => List.unmodifiable(_samples);

  List<Trip> tripsForProfile(String profileId) {
    final trips = _tripsByProfile[profileId] ?? const [];
    return List.unmodifiable(trips);
  }

  bool hasTrips(String profileId) =>
      (_tripsByProfile[profileId]?.isNotEmpty ?? false);

  Future<void> loadTrips() async {
    final stored = await _storage.loadTrips();
    _tripsByProfile
      ..clear();
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
    _startTime = DateTime.now();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds += 1;
      notifyListeners();
    });
    notifyListeners();
  }

  void addSample(TripSample sample) {
    if (!_running) return;
    _samples.add(sample);
  }

  Future<Trip?> stopTrip() async {
    if (!_running || _activeProfile == null) return null;
    _timer?.cancel();
    _timer = null;
    _running = false;

    final profileId = _activeProfile!.id;
    final endTime = DateTime.now();
    final duration = _elapsedSeconds;
    final totalFuel =
        _samples.fold<double>(0.0, (sum, sample) => sum + sample.fuelMlPerSec);
    final double avgFuel =
        _samples.isEmpty ? 0.0 : totalFuel / _samples.length;

    final csvPath = await _fileService.saveTripSamples(profileId, List.of(_samples));

    final trip = Trip(
      id: 'trip-${DateTime.now().millisecondsSinceEpoch}',
      profileId: profileId,
      startTime: _startTime ?? endTime,
      endTime: endTime,
      durationSeconds: duration,
      totalFuelMl: totalFuel,
      avgFuelMlPerSec: avgFuel,
      dataFilePath: csvPath,
    );

    final list = _tripsByProfile.putIfAbsent(profileId, () => []);
    list.insert(0, trip);
    _lastTrip = trip;
    await _storage.saveTrip(trip);

    _activeProfile = null;
    _elapsedSeconds = 0;
    _samples.clear();
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
}
