import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../models/trip.dart';
import '../../models/trip_sample.dart';
import '../../state/trip_provider.dart';
import '../../widgets/confirm_dialog.dart';
import 'trip_chart.dart';

class TripDetailsArguments {
  TripDetailsArguments({required this.profileName, required this.trip});

  final String profileName;
  final Trip trip;
}

class TripDetailsPage extends StatefulWidget {
  const TripDetailsPage({super.key, required this.arguments});

  final TripDetailsArguments arguments;

  @override
  State<TripDetailsPage> createState() => _TripDetailsPageState();
}

class _TripDetailsPageState extends State<TripDetailsPage> {
  bool _loading = true;
  String? _error;
  List<TripSample> _samples = [];

  @override
  void initState() {
    super.initState();
    _loadSamples();
  }

  Future<void> _loadSamples() async {
    final path = widget.arguments.trip.dataFilePath;
    if (path == null) {
      setState(() {
        _samples = [];
        _loading = false;
      });
      return;
    }
    try {
      final samples = await context.read<TripProvider>().loadSamples(path);
      if (!mounted) return;
      setState(() {
        _samples = samples;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Failed to load trip data.';
        _loading = false;
      });
    }
  }

  Future<void> _deleteTrip() async {
    final trips = context.read<TripProvider>();
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete trip',
      message: 'Delete this trip permanently?',
    );
    if (!confirmed) return;
    final profileId = widget.arguments.trip.profileId;
    final tripId = widget.arguments.trip.id;
    await trips.deleteTrip(profileId, tripId);
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    navigator.pop();
    messenger.showSnackBar(const SnackBar(content: Text('Trip deleted')));
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.arguments.trip;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip Details'),
        actions: [
          IconButton(
            tooltip: 'Delete trip',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteTrip,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.arguments.profileName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _StatCell(label: 'Date', value: formatDate(trip.startTime)),
                _StatCell(
                    label: 'Duration',
                    value: formatDuration(trip.durationSeconds)),
                _StatCell(label: 'Fuel', value: formatFuel(trip.totalFuelMl)),
                _StatCell(
                    label: 'Distance',
                    value: formatDistance(trip.distanceKm)),
                _StatCell(
                    label: 'Avg L/100',
                    value: formatConsumption(trip.avgConsumptionLPer100Km)),
                _StatCell(
                    label: 'Avg flow',
                    value:
                        '${trip.avgFuelMlPerSec.toStringAsFixed(2)} mL/s'),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDarkElevated,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.surfaceDarkOutline),
                ),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          )
                        : TripChart(samples: _samples),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
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
            label.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
