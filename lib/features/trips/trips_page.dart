import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../models/trip.dart';
import '../../state/profile_provider.dart';
import '../../state/trip_provider.dart';
import 'trip_details_page.dart';

class TripsPage extends StatelessWidget {
  const TripsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileProvider>().selectedProfile;
    if (profile == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Select a profile to see trips.'),
        ),
      );
    }

    final trips = context.watch<TripProvider>().tripsForProfile(profile.id);
    if (trips.isEmpty) {
      return const Center(child: Text('No trips recorded yet.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: trips.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, index) {
        final trip = trips[index];
        return _TripCard(profileName: profile.name, trip: trip);
      },
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.profileName, required this.trip});

  final String profileName;
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(formatDate(trip.startTime)),
        subtitle: Text('Duration: ${formatDuration(trip.durationSeconds)}'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(formatFuel(trip.totalFuelMl),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('${trip.avgFuelMlPerSec.toStringAsFixed(2)} mL/s'),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TripDetailsPage(
              arguments: TripDetailsArguments(profileName: profileName, trip: trip),
            ),
          ),
        ),
      ),
    );
  }
}
