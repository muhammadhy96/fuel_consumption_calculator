import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../models/car_profile.dart';
import '../../state/obd_provider.dart';
import '../../state/trip_provider.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/value_card.dart';

class LiveDashboard extends StatelessWidget {
  const LiveDashboard({
    super.key,
    required this.profile,
    required this.fuelFlow,
  });

  final CarProfile profile;
  final double fuelFlow;

  @override
  Widget build(BuildContext context) {
    final obd = context.watch<ObdProvider>();
    final trip = context.watch<TripProvider>();

    final statusColor = trip.running
        ? Colors.green
        : obd.connected
            ? Colors.orange
            : Colors.red;
    final statusLabel = trip.running
        ? 'Trip running'
        : obd.connected
            ? 'Connected'
            : 'Not connected';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(profile.name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('${profile.fuelType} • '
                    '${profile.engineDisplacement != null ? '${profile.engineDisplacement}L' : 'engine TBD'}'),
                const SizedBox(height: 12),
                StatusBadge(label: statusLabel, color: statusColor),
                const SizedBox(height: 12),
                Text('Elapsed: ${formatDuration(trip.elapsedSeconds)}'),
                const SizedBox(height: 8),
                Text(
                  obd.lastUpdate != null
                      ? 'Last update: ${formatTimestamp(obd.lastUpdate!)}'
                      : 'No data yet from OBD',
                ),
                if (obd.lastRawMessage != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Last frame: ${obd.lastRawMessage}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ValueCard(
          label: 'Fuel Flow',
          value: '${fuelFlow.toStringAsFixed(2)} mL/s',
          highlight: true,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ValueCard(label: 'RPM', value: obd.rpm.toStringAsFixed(0)),
            ValueCard(
              label: 'MAP',
              value: '${obd.mapKpa.toStringAsFixed(0)} kPa',
            ),
            ValueCard(
              label: 'IAT',
              value: obd.iatKelvin > 0
                  ? '${(obd.iatKelvin - 273.15).toStringAsFixed(0)} °C'
                  : '--',
            ),
          ],
        ),
      ],
    );
  }
}
