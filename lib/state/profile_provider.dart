import 'package:flutter/material.dart';

import '../core/services/storage_service.dart';
import '../models/car_profile.dart';

class ProfileProvider extends ChangeNotifier {
  ProfileProvider(this._storage);

  final StorageService _storage;
  final List<CarProfile> _profiles = [];
  CarProfile? _selectedProfile;

  List<CarProfile> get profiles => List.unmodifiable(_profiles);

  CarProfile? get selectedProfile => _selectedProfile;

  Future<void> loadProfiles() async {
    final stored = await _storage.loadProfiles();
    _profiles
      ..clear()
      ..addAll(stored);
    _selectedProfile = _profiles.isNotEmpty ? _profiles.first : null;
    notifyListeners();
  }

  void selectProfile(CarProfile profile) {
    if (_selectedProfile?.id == profile.id) return;
    _selectedProfile = profile;
    notifyListeners();
  }

  Future<void> addProfile(CarProfile profile) async {
    _profiles.add(profile);
    _selectedProfile ??= profile;
    await _storage.saveProfile(profile);
    notifyListeners();
  }

  Future<void> updateProfile(CarProfile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index == -1) return;
    _profiles[index] = profile;
    _selectedProfile = _selectedProfile?.id == profile.id
        ? profile
        : _selectedProfile;
    await _storage.saveProfile(profile);
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    if (_selectedProfile?.id == id) {
      _selectedProfile = _profiles.isEmpty ? null : _profiles.first;
    }
    await _storage.deleteProfile(id);
    notifyListeners();
  }
}
