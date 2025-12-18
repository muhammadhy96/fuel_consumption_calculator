import 'profile_provider.dart';
import 'obd_provider.dart';
import 'trip_provider.dart';

class AppState {
  AppState({
    required this.profiles,
    required this.obd,
    required this.trips,
  });

  final ProfileProvider profiles;
  final ObdProvider obd;
  final TripProvider trips;
}
