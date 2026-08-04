import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Select a profile to see trips.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
          ),
        ),
      );
    }

    final trips = context.watch<TripProvider>().tripsForProfile(profile.id);
    if (trips.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.route_outlined,
                size: 72, color: Colors.white.withValues(alpha: 0.22)),
            const SizedBox(height: 14),
            const Text(
              'No trips recorded yet',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Start a trip from the Drive tab.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
            ),
          ],
        ),
      );
    }

    final totalFuel = trips.fold<double>(0, (sum, t) => sum + t.totalFuelMl);
    final totalDist = trips.fold<double>(0, (sum, t) => sum + t.distanceKm);
    final avgConsumption = totalDist > 0
        ? (totalFuel / 1000) / totalDist * 100
        : 0.0;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: trips.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        if (index == 0) {
          return _AggregateHeader(
            totalTrips: trips.length,
            totalFuelL: totalFuel / 1000,
            totalDistanceKm: totalDist,
            avgConsumption: avgConsumption,
          );
        }
        final trip = trips[index - 1];
        return _TripCard(profileName: profile.name, trip: trip);
      },
    );
  }
}

class _AggregateHeader extends StatelessWidget {
  const _AggregateHeader({
    required this.totalTrips,
    required this.totalFuelL,
    required this.totalDistanceKm,
    required this.avgConsumption,
  });

  final int totalTrips;
  final double totalFuelL;
  final double totalDistanceKm;
  final double avgConsumption;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.accentCyan.withValues(alpha: 0.18),
            AppTheme.accentViolet.withValues(alpha: 0.12),
          ],
        ),
        border: Border.all(color: AppTheme.surfaceDarkOutline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LIFETIME TOTALS',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 11,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _AggStat(
                  label: 'Trips',
                  value: totalTrips.toString(),
                  unit: '',
                ),
              ),
              Expanded(
                child: _AggStat(
                  label: 'Distance',
                  value: totalDistanceKm.toStringAsFixed(1),
                  unit: 'km',
                ),
              ),
              Expanded(
                child: _AggStat(
                  label: 'Fuel',
                  value: totalFuelL.toStringAsFixed(2),
                  unit: 'L',
                ),
              ),
              Expanded(
                child: _AggStat(
                  label: 'Avg',
                  value: avgConsumption > 0
                      ? avgConsumption.toStringAsFixed(1)
                      : '--',
                  unit: 'L/100',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AggStat extends StatelessWidget {
  const _AggStat({required this.label, required this.value, required this.unit});
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(
                unit,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.profileName, required this.trip});

  final String profileName;
  final Trip trip;

  Color _efficiencyColor(double lPer100km) {
    if (lPer100km <= 0 || !lPer100km.isFinite) return AppTheme.accentCyan;
    if (lPer100km < 6) return AppTheme.accentLime;
    if (lPer100km < 10) return AppTheme.accentAmber;
    return AppTheme.accentMagenta;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TripDetailsPage(
            arguments: TripDetailsArguments(
                profileName: profileName, trip: trip),
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDarkElevated,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.surfaceDarkOutline),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppTheme.accentCyan.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.route, color: AppTheme.accentCyan),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatDate(trip.startTime),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatDuration(trip.durationSeconds)} · ${formatDistance(trip.distanceKm)}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatFuel(trip.totalFuelMl),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatConsumption(trip.avgConsumptionLPer100Km),
                  style: TextStyle(
                    color: _efficiencyColor(trip.avgConsumptionLPer100Km),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
