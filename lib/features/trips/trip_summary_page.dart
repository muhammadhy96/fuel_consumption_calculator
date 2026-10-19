import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../models/car_profile.dart';
import '../../models/trip.dart';
import '../../models/trip_sample.dart';
import '../../widgets/cost_breakdown_bar.dart';
import 'trip_chart.dart';
import 'trip_export_actions.dart';

class TripSummaryPage extends StatelessWidget {
  const TripSummaryPage({
    super.key,
    required this.profile,
    required this.trip,
    required this.samples,
  });

  final CarProfile profile;
  final Trip trip;
  final List<TripSample> samples;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip Summary'),
        actions: [
          TripExportActions(trip: trip, profileName: profile.name),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              profile.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 12),
            _StatGrid(
              stats: [
                _StatEntry('Duration', formatDuration(trip.durationSeconds)),
                _StatEntry('Fuel used', formatFuel(trip.totalFuelMl)),
                _StatEntry('Distance', formatDistance(trip.distanceKm)),
                if (trip.obdDistanceKm != null)
                  _StatEntry(
                    'OBD distance',
                    formatDistance(trip.obdDistanceKm!),
                  ),
                _StatEntry(
                  'Avg consumption',
                  formatConsumption(trip.avgConsumptionLPer100Km),
                ),
                _StatEntry(
                  'Avg flow',
                  '${trip.avgFuelMlPerSec.toStringAsFixed(2)} mL/s',
                ),
                if (trip.totalCost != null) ...[
                  _StatEntry('Fuel cost', formatCost(trip.fuelCost!)),
                  // C_trip needs k_m and k_t; without them it is unknown.
                  _StatEntry(
                    'Trip cost',
                    trip.costIsFullModel ? formatCost(trip.totalCost!) : '--',
                  ),
                  _StatEntry(
                    trip.costIsFullModel ? 'Cost / km' : 'Fuel cost / km',
                    formatCostPerKm(trip.costPerKm),
                  ),
                  if (trip.costIsFullModel)
                    _StatEntry('Fuel share', formatShare(trip.fuelCostShare)),
                ],
              ],
            ),
            if (trip.cost case final cost? when cost.isFullModel) ...[
              const SizedBox(height: 14),
              CostBreakdownBar(items: cost.perKmBreakdown),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDarkElevated,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.surfaceDarkOutline),
                ),
                child: samples.isEmpty
                    ? const Center(
                        child: Text(
                          'No samples recorded.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : TripChart(samples: samples),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatEntry {
  const _StatEntry(this.label, this.value);
  final String label;
  final String value;
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});
  final List<_StatEntry> stats;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final stat in stats)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceDarkElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.surfaceDarkOutline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  stat.label.toUpperCase(),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  stat.value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
