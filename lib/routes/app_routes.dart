import 'package:flutter/material.dart';

import '../features/drive/drive_page.dart';
import '../features/profiles/profiles_page.dart';
import '../features/trips/trip_details_page.dart';
import '../features/trips/trips_page.dart';

class AppRoutes {
  static const home = '/';
  static const drive = '/drive';
  static const profiles = '/profiles';
  static const trips = '/trips';
  static const tripDetails = '/trip-details';

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case drive:
        return MaterialPageRoute(builder: (_) => const DrivePage());
      case profiles:
        return MaterialPageRoute(builder: (_) => const ProfilesPage());
      case trips:
        return MaterialPageRoute(builder: (_) => const TripsPage());
      case tripDetails:
        final args = settings.arguments as TripDetailsArguments;
        return MaterialPageRoute(
          builder: (_) => TripDetailsPage(arguments: args),
        );
      case home:
      default:
        return MaterialPageRoute(builder: (_) => const DrivePage());
    }
  }
}
