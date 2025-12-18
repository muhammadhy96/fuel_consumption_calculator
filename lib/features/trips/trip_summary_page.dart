import 'package:flutter/material.dart';

import '../../core/utils/formatters.dart';
import '../../models/car_profile.dart';
import '../../models/trip.dart';
import '../../models/trip_sample.dart';
import 'trip_chart.dart';

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
      appBar: AppBar(title: const Text('Trip Summary')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _Stat(label: 'Duration', value: formatDuration(trip.durationSeconds)),
                _Stat(label: 'Fuel used', value: formatFuel(trip.totalFuelMl)),
                _Stat(
                    label: 'Avg flow',
                    value: '${trip.avgFuelMlPerSec.toStringAsFixed(2)} mL/s'),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: samples.isEmpty
                  ? const Center(child: Text('No samples recorded.'))
                  : TripChart(samples: samples),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}
