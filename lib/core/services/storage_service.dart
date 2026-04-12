import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/car_profile.dart';
import '../../models/trip.dart';

class StorageService {
  static const String profilesBoxName = 'profiles_box';
  static const String tripsBoxName = 'trips_box';

  Box<Map<dynamic, dynamic>>? _profilesBox;
  Box<Map<dynamic, dynamic>>? _tripsBox;
  Future<void>? _initFuture;

  Future<void> init() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> _initInternal() async {
    await Hive.initFlutter();
    _profilesBox ??=
        await Hive.openBox<Map<dynamic, dynamic>>(profilesBoxName);
    _tripsBox ??= await Hive.openBox<Map<dynamic, dynamic>>(tripsBoxName);
  }

  Future<void> _ensureInitialized() async {
    if (_profilesBox != null && _tripsBox != null) return;
    await init();
  }

  Future<List<CarProfile>> loadProfiles() async {
    await _ensureInitialized();
    final profiles = <CarProfile>[];
    for (final value in _profilesBox!.values) {
      try {
        profiles.add(
          CarProfile.fromMap(Map<String, dynamic>.from(value)),
        );
      } catch (err) {
        debugPrint('Skipping malformed profile record: $err');
      }
    }
    return profiles;
  }

  Future<void> saveProfile(CarProfile profile) async {
    await _ensureInitialized();
    await _profilesBox!.put(profile.id, profile.toMap());
  }

  Future<void> deleteProfile(String id) async {
    await _ensureInitialized();
    await _profilesBox!.delete(id);
  }

  Future<List<Trip>> loadTrips() async {
    await _ensureInitialized();
    final trips = <Trip>[];
    for (final value in _tripsBox!.values) {
      try {
        trips.add(
          Trip.fromMap(Map<String, dynamic>.from(value)),
        );
      } catch (err) {
        debugPrint('Skipping malformed trip record: $err');
      }
    }
    return trips;
  }

  Future<void> saveTrip(Trip trip) async {
    await _ensureInitialized();
    await _tripsBox!.put(trip.id, trip.toMap());
  }

  Future<void> deleteTrip(String id) async {
    await _ensureInitialized();
    await _tripsBox!.delete(id);
  }
}
