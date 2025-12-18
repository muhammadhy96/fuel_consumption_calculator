import 'package:hive_flutter/hive_flutter.dart';

import '../../models/car_profile.dart';
import '../../models/trip.dart';

class StorageService {
  static const String profilesBoxName = 'profiles_box';
  static const String tripsBoxName = 'trips_box';

  Box? _profilesBox;
  Box? _tripsBox;

  Future<void> init() async {
    await Hive.initFlutter();
    _profilesBox ??= await Hive.openBox(profilesBoxName);
    _tripsBox ??= await Hive.openBox(tripsBoxName);
  }

  Future<List<CarProfile>> loadProfiles() async {
    final values = _profilesBox?.values ?? [];
    return values
        .map((value) => CarProfile.fromMap(Map<String, dynamic>.from(value)))
        .toList();
  }

  Future<void> saveProfile(CarProfile profile) async {
    await _profilesBox?.put(profile.id, profile.toMap());
  }

  Future<void> deleteProfile(String id) async {
    await _profilesBox?.delete(id);
  }

  Future<List<Trip>> loadTrips() async {
    final values = _tripsBox?.values ?? [];
    return values
        .map((value) => Trip.fromMap(Map<String, dynamic>.from(value)))
        .toList();
  }

  Future<void> saveTrip(Trip trip) async {
    await _tripsBox?.put(trip.id, trip.toMap());
  }

  Future<void> deleteTrip(String id) async {
    await _tripsBox?.delete(id);
  }
}
