import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../features/drive/connect_button.dart';
import '../../features/drive/live_dashboard.dart';
import '../../features/trips/trip_summary_page.dart';
import '../../models/car_profile.dart';
import '../../models/trip_sample.dart';
import '../../state/obd_provider.dart';
import '../../state/profile_provider.dart';
import '../../state/trip_provider.dart';
import '../../widgets/value_card.dart';

class DrivePage extends StatefulWidget {
  const DrivePage({super.key});

  @override
  State<DrivePage> createState() => _DrivePageState();
}

class _DrivePageState extends State<DrivePage> {
  Timer? _sampleTimer;
  double _fuelFlow = 0;
  double _timeSeconds = 0;
  List<FlSpot> _chartPoints = [];

  @override
  void dispose() {
    _sampleTimer?.cancel();
    super.dispose();
  }

  Future<bool> _requestPermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final location = await Permission.location.request();
    final granted = scan.isGranted && connect.isGranted && location.isGranted;
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Bluetooth and location permissions are required.'),
      ));
    }
    return granted;
  }

  Future<bool> _connectDevice() async {
    if (!await _requestPermissions()) return false;
    final obd = context.read<ObdProvider>();
    final devices = await obd.getPairedDevices();
    if (!mounted) return false;
    final device = await showDialog<BluetoothDevice>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Select OBD device'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: devices.isEmpty
              ? const Center(child: Text('No paired devices found.'))
              : ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (_, index) {
                    final device = devices[index];
                    return ListTile(
                      title: Text(device.name ?? 'Unknown'),
                      subtitle: Text(device.address),
                      onTap: () => Navigator.of(context).pop(device),
                    );
                  },
                ),
        ),
      ),
    );
    if (device == null) return false;
    await obd.connect(device);
    final sample = await obd.verifyConnection();
    if (mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(
        content: Text(
          sample != null
              ? 'OBD data received: $sample'
              : 'Connected to ${device.name ?? 'device'}, waiting for data...',
        ),
      ));
    }
    return true;
  }

  Future<void> _startTrip() async {
    final profile = context.read<ProfileProvider>().selectedProfile;
    if (profile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a profile first.')),
      );
      return;
    }
    final obd = context.read<ObdProvider>();
    if (!obd.connected) {
      final connected = await _connectDevice();
      if (!connected) return;
    }
    await obd.startLive();
    context.read<TripProvider>().startTrip(profile);

    setState(() {
      _chartPoints = [];
      _fuelFlow = 0;
      _timeSeconds = 0;
    });

    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _collectSample(profile);
    });
  }

  void _collectSample(CarProfile profile) {
    final obd = context.read<ObdProvider>();
    final trip = context.read<TripProvider>();
    final fuel = obd.calculateFuelFlow();
    _timeSeconds += 1;
    final sample = TripSample(
      timeSeconds: _timeSeconds,
      rpm: obd.rpm,
      mapKpa: obd.mapKpa,
      iatKelvin: obd.iatKelvin,
      fuelMlPerSec: fuel,
    );
    trip.addSample(sample);
    setState(() {
      _fuelFlow = fuel;
      _chartPoints.add(FlSpot(_timeSeconds, fuel));
      if (_chartPoints.length > 600) _chartPoints.removeAt(0);
    });
  }

  Future<void> _stopTrip() async {
    _sampleTimer?.cancel();
    final profile = context.read<ProfileProvider>().selectedProfile;
    final tripProvider = context.read<TripProvider>();
    final samplesSnapshot = List<TripSample>.from(tripProvider.samples);
    final trip = await tripProvider.stopTrip();
    context.read<ObdProvider>().stopLive();
    if (!mounted || profile == null || trip == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripSummaryPage(
          profile: profile,
          trip: trip,
          samples: samplesSnapshot,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileProvider>().selectedProfile;
    final trip = context.watch<TripProvider>();
    if (profile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('No profile selected.'),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Go to Profiles tab to add one.')),
                ),
                child: const Text('Add profile'),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LiveDashboard(profile: profile, fuelFlow: _fuelFlow),
          const SizedBox(height: 16),
          Text('Fuel flow (mL/s) over time (s)',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 250,
            child: LineChart(
              _buildFuelChart(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: trip.running ? null : _startTrip,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Trip'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: trip.running ? _stopTrip : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Trip'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ConnectButton(
              connected: context.watch<ObdProvider>().connected,
              tripRunning: trip.running,
              onPressed: _connectDevice,
            ),
          ),
        ],
      ),
    );
  }

  LineChartData _buildFuelChart() {
    if (_chartPoints.isEmpty) {
      return _chartDataFor(
        points: const [FlSpot(0, 0)],
        viewStart: 0,
        viewEnd: 1,
      );
    }
    final maxX = _chartPoints.last.x;
    final viewStart = maxX > 60 ? maxX - 60 : 0.0;
    final visiblePoints =
        _chartPoints.where((point) => point.x >= viewStart).toList();
    final safePoints =
        visiblePoints.isEmpty ? const [FlSpot(0, 0)] : visiblePoints;
    return _chartDataFor(
      points: safePoints,
      viewStart: viewStart,
      viewEnd: maxX,
    );
  }

  LineChartData _chartDataFor({
    required List<FlSpot> points,
    required double viewStart,
    required double viewEnd,
  }) {
    final adjustedEnd = viewEnd == viewStart ? viewStart + 1 : viewEnd;
    return LineChartData(
      minX: viewStart,
      maxX: adjustedEnd,
      minY: 0,
      lineBarsData: [
        LineChartBarData(
          spots: points,
          isCurved: true,
          color: Colors.teal,
          barWidth: 3,
          dotData: const FlDotData(show: false),
        ),
      ],
      gridData: const FlGridData(show: true),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          axisNameWidget: const Text('Time (s)'),
          sideTitles: SideTitles(
            showTitles: true,
            interval: 10,
            reservedSize: 28,
            getTitlesWidget: (value, meta) => Text(value.toInt().toString()),
          ),
        ),
        leftTitles: AxisTitles(
          axisNameWidget: const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Text('mL/s'),
          ),
          sideTitles: SideTitles(
            showTitles: true,
            interval: 5,
            reservedSize: 40,
            getTitlesWidget: (value, meta) =>
                Text(value.toStringAsFixed(0)),
          ),
        ),
      ),
    );
  }
}
