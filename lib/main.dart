import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/services/file_service.dart';
import 'core/services/obd_service.dart';
import 'core/services/storage_service.dart';
import 'state/app_state.dart';
import 'state/obd_provider.dart';
import 'state/profile_provider.dart';
import 'state/trip_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService();
  await storage.init();
  final fileService = FileService();

  final profileProvider = ProfileProvider(storage);
  await profileProvider.loadProfiles();
  final tripProvider = TripProvider(fileService, storage);
  await tripProvider.loadTrips();
  final obdProvider = ObdProvider(ObdService());

  final appState = AppState(
    profiles: profileProvider,
    obd: obdProvider,
    trips: tripProvider,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ProfileProvider>.value(value: profileProvider),
        ChangeNotifierProvider<ObdProvider>.value(value: obdProvider),
        ChangeNotifierProvider<TripProvider>.value(value: tripProvider),
        Provider<AppState>.value(value: appState),
      ],
      child: const FuelApp(),
    ),
  );
}
