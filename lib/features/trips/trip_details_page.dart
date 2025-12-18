import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete trip',
      message: 'Delete this trip permanently?',
    );
    if (!confirmed) return;
    final profileId = widget.arguments.trip.profileId;
    final tripId = widget.arguments.trip.id;
    await context.read<TripProvider>().deleteTrip(profileId, tripId);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Trip deleted')));
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.arguments.trip;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _deleteTrip,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.arguments.profileName,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _Stat(label: 'Date', value: formatDate(trip.startTime)),
                _Stat(label: 'Duration', value: formatDuration(trip.durationSeconds)),
                _Stat(label: 'Fuel', value: formatFuel(trip.totalFuelMl)),
                _Stat(
                    label: 'Avg flow',
                    value: '${trip.avgFuelMlPerSec.toStringAsFixed(2)} mL/s'),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!))
                      : TripChart(samples: _samples),
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
