import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../features/drive/connect_button.dart';
import '../../features/drive/live_dashboard.dart';
import '../../features/trips/trip_summary_page.dart';
import '../../models/car_profile.dart';
import '../../models/trip_sample.dart';
import '../../state/obd_provider.dart';
import '../../state/profile_provider.dart';
import '../../state/trip_provider.dart';

class DrivePage extends StatefulWidget {
  const DrivePage({super.key});

  @override
  State<DrivePage> createState() => _DrivePageState();
}

class _DrivePageState extends State<DrivePage> {
  final Stopwatch _sampleStopwatch = Stopwatch();
  static const int _uiUpdateIntervalMs = 100;
  static const int _chartUpdateIntervalMs = 400;

  double _fuelFlow = 0;
  double _timeSeconds = 0;
  LiveTripStats _tripStats = LiveTripStats.zero;
  final List<FlSpot> _chartPoints = [];
  final List<FlSpot> _rpmChartPoints = [];
  final List<FlSpot> _speedChartPoints = [];
  int _lastChartUpdateMs = 0;
  int _lastUiUpdateMs = 0;
  CarProfile? _activeProfile;

  double _totalFuelMl = 0;
  double _distanceKm = 0;
  double? _previousTime;
  double _previousFuel = 0;
  double _previousSpeed = 0;
  final List<double> _recentFuel = [];
  final List<double> _recentSpeed = [];
  static const int _instantWindow = 20;
  double _fuelPricePerLiter = 0;

  @override
  void dispose() {
    _sampleStopwatch.stop();
    final obd = context.read<ObdProvider>();
    obd.onFrame = null;
    unawaited(obd.stopLive());
    super.dispose();
  }

  Future<bool> _requestPermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final location = await Permission.location.request();
    final granted = scan.isGranted && connect.isGranted && location.isGranted;
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth and location permissions are required.'),
        ),
      );
    }
    return granted;
  }

  Future<bool> _connectDevice() async {
    if (!await _requestPermissions()) return false;
    if (!mounted) return false;
    final obd = context.read<ObdProvider>();
    List<BluetoothDevice> devices;
    try {
      devices = await obd.getPairedDevices();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load paired devices: $err')),
        );
      }
      return false;
    }
    if (!mounted) return false;
    final device = await showDialog<BluetoothDevice>(
      context: context,
      builder: (_) => _DeviceDialog(devices: devices),
    );
    if (device == null) return false;
    try {
      await obd.connect(device);
      final sample = await obd.verifyConnection();
      await obd.startLive();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              sample != null
                  ? 'Connected — receiving OBD frames'
                  : 'Connected to ${device.name ?? 'device'}, waiting for data...',
            ),
          ),
        );
      }
      return true;
    } catch (err) {
      if (mounted) {
        final msg = _classifyObdError(err);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
      return false;
    }
  }

  Future<void> _startTrip() async {
    final profile = context.read<ProfileProvider>().selectedProfile;
    final tripProvider = context.read<TripProvider>();
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
    if (!mounted) return;
    tripProvider.startTrip(profile);
    _activeProfile = profile;

    setState(() {
      _chartPoints.clear();
      _rpmChartPoints.clear();
      _speedChartPoints.clear();
      _fuelFlow = 0;
      _timeSeconds = 0;
      _lastChartUpdateMs = 0;
      _lastUiUpdateMs = 0;
      _totalFuelMl = 0;
      _distanceKm = 0;
      _previousTime = null;
      _previousFuel = 0;
      _previousSpeed = 0;
      _recentFuel.clear();
      _recentSpeed.clear();
      _tripStats = LiveTripStats.zero;
      _fuelPricePerLiter = profile.fuelPricePerLiter;
    });
    _sampleStopwatch
      ..reset()
      ..start();
    obd.onFrame = _onObdFrame;
  }

  int _computeEcoScore(double rpm, double avgL100) {
    if (_distanceKm < 0.1) return 0;
    // RPM component: lower is better. Sweet spot is 1200-2500.
    double rpmScore;
    if (rpm <= 0) {
      rpmScore = 50;
    } else if (rpm < 1200) {
      rpmScore = 70;
    } else if (rpm < 2500) {
      rpmScore = 100;
    } else if (rpm < 3500) {
      rpmScore = 60;
    } else {
      rpmScore = 20;
    }
    // Consumption component: lower L/100km is better.
    double consumptionScore;
    if (avgL100 <= 0 || !avgL100.isFinite) {
      consumptionScore = 50;
    } else if (avgL100 < 5) {
      consumptionScore = 100;
    } else if (avgL100 < 8) {
      consumptionScore = 80;
    } else if (avgL100 < 12) {
      consumptionScore = 50;
    } else {
      consumptionScore = 20;
    }
    return ((rpmScore * 0.4 + consumptionScore * 0.6)).round().clamp(0, 100);
  }

  String _classifyObdError(Object err) {
    final msg = err.toString().toLowerCase();
    if (msg.contains('bluetooth') && msg.contains('off')) {
      return 'Bluetooth is turned off. Enable it in system settings.';
    }
    if (msg.contains('connect_error') || msg.contains('connection refused')) {
      return 'Cannot reach the OBD adapter. Is it plugged in and powered?';
    }
    if (msg.contains('timeout')) {
      return 'ELM327 did not respond in time. Try reconnecting.';
    }
    if (msg.contains('permission')) {
      return 'Bluetooth permission denied. Grant it in app settings.';
    }
    return 'OBD connection failed: $err';
  }

  void _onObdFrame() {
    if (!mounted) return;
    final profile = _activeProfile;
    if (profile == null) return;
    _collectSample(profile);
  }

  void _collectSample(CarProfile profile) {
    if (!mounted) return;
    final obd = context.read<ObdProvider>();
    final trip = context.read<TripProvider>();
    const double defaultVePercent = 85;
    final vePercent = obd.engineLoadPercent ?? defaultVePercent;
    final rawFuel = obd.calculateFuelFlow(
      volumetricEfficiency: vePercent,
      engineDisplacementLiters: profile.engineDisplacement ?? 2.0,
    );
    final fuel = rawFuel.isFinite && rawFuel >= 0 ? rawFuel : 0.0;
    _timeSeconds = _sampleStopwatch.elapsedMilliseconds / 1000.0;
    final smoothFuel = obd.pushFuelSample(fuel);

    final sample = TripSample(
      timeSeconds: _timeSeconds,
      rpm: obd.rpm,
      mapKpa: obd.mapKpa,
      speedKph: obd.speedKph,
      iatKelvin: obd.iatKelvin,
      fuelMlPerSec: fuel,
      engineLoadPercent: obd.engineLoadPercent ?? 0,
      mafGramsPerSec: obd.mafGramsPerSec,
      equivRatio: obd.equivRatio,
    );
    trip.addSample(sample);

    if (_previousTime != null) {
      final dt = _timeSeconds - _previousTime!;
      if (dt > 0 && dt < 5) {
        final avgFuel = (_previousFuel + fuel) / 2;
        _totalFuelMl += avgFuel * dt;
        final avgSpeed = (_previousSpeed + obd.speedKph) / 2;
        _distanceKm += (avgSpeed * dt) / 3600;
      }
    }
    _previousTime = _timeSeconds;
    _previousFuel = fuel;
    _previousSpeed = obd.speedKph;

    _recentFuel.add(fuel);
    _recentSpeed.add(obd.speedKph);
    if (_recentFuel.length > _instantWindow) {
      _recentFuel.removeAt(0);
      _recentSpeed.removeAt(0);
    }

    final nowMs = _sampleStopwatch.elapsedMilliseconds;
    final shouldUpdateChart =
        nowMs - _lastChartUpdateMs >= _chartUpdateIntervalMs;
    final shouldUpdateUi = nowMs - _lastUiUpdateMs >= _uiUpdateIntervalMs;
    if (!shouldUpdateChart && !shouldUpdateUi) return;
    if (!mounted) return;

    final avgConsumption = _distanceKm > 0
        ? (_totalFuelMl / 1000) / _distanceKm * 100
        : 0.0;

    final instantConsumption = _computeInstantConsumption();
    final costEstimate =
        _fuelPricePerLiter > 0 ? (_totalFuelMl / 1000) * _fuelPricePerLiter : 0.0;
    final ecoScore = _computeEcoScore(obd.rpm, avgConsumption);

    setState(() {
      if (shouldUpdateUi) {
        _fuelFlow = smoothFuel;
        _lastUiUpdateMs = nowMs;
        _tripStats = LiveTripStats(
          totalFuelMl: _totalFuelMl,
          distanceKm: _distanceKm,
          avgConsumptionLPer100km: avgConsumption,
          instantConsumptionLPer100km: instantConsumption,
          costEstimate: costEstimate,
          elapsedSeconds: trip.elapsedSeconds,
          ecoScore: ecoScore,
        );
      }
      if (shouldUpdateChart) {
        _chartPoints.add(FlSpot(_timeSeconds, smoothFuel));
        _rpmChartPoints.add(FlSpot(_timeSeconds, obd.rpm / 100));
        _speedChartPoints.add(FlSpot(_timeSeconds, obd.speedKph / 10));
        if (_chartPoints.length > 1500) {
          _chartPoints.removeAt(0);
          _rpmChartPoints.removeAt(0);
          _speedChartPoints.removeAt(0);
        }
        _lastChartUpdateMs = nowMs;
      }
    });
  }

  double _computeInstantConsumption() {
    if (_recentFuel.length < 4) return 0;
    double fuelSum = 0;
    double speedSum = 0;
    for (var i = 0; i < _recentFuel.length; i++) {
      fuelSum += _recentFuel[i];
      speedSum += _recentSpeed[i];
    }
    final avgFuel = fuelSum / _recentFuel.length;
    final avgSpeed = speedSum / _recentSpeed.length;
    if (avgSpeed < 5) return 0;
    // mL/s ÷ km/s ÷ 1000 × 100 = L/100km
    return (avgFuel * 3600) / avgSpeed / 10;
  }

  Future<void> _stopTrip() async {
    _sampleStopwatch.stop();
    final obd = context.read<ObdProvider>();
    final profileProvider = context.read<ProfileProvider>();
    final tripProvider = context.read<TripProvider>();
    obd.onFrame = null;
    try {
      await obd.stopLive();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stop live OBD stream: $err')),
        );
      }
    }
    final profile = profileProvider.selectedProfile;
    final samplesSnapshot = List<TripSample>.from(tripProvider.samples);
    final trip = await tripProvider.stopTrip();
    _activeProfile = null;
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
    final tripRunning = context.select<TripProvider, bool>((t) => t.running);
    final connected = context.select<ObdProvider, bool>((o) => o.connected);
    if (profile == null) {
      return _buildNoProfile(context);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LiveDashboard(
            profile: profile,
            fuelFlow: _fuelFlow,
            tripStats: _tripStats,
          ),
          const SizedBox(height: 18),
          _buildChartCard(context),
          const SizedBox(height: 18),
          _buildActionRow(tripRunning: tripRunning, connected: connected),
        ],
      ),
    );
  }

  Widget _buildNoProfile(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_car_outlined,
                size: 72, color: Colors.white.withValues(alpha: 0.25)),
            const SizedBox(height: 16),
            const Text(
              'No profile selected',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Create one in the Profiles tab to start recording trips.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChartCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDarkElevated,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.surfaceDarkOutline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.show_chart,
                  color: AppTheme.accentCyan, size: 18),
              const SizedBox(width: 8),
              Text(
                'FUEL FLOW · LAST 60 s',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
              const Spacer(),
              Text(
                '${_fuelFlow.toStringAsFixed(2)} mL/s',
                style: const TextStyle(
                  color: AppTheme.accentCyan,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _LegendDot(color: AppTheme.accentCyan, label: 'Fuel'),
              const SizedBox(width: 12),
              _LegendDot(
                  color: AppTheme.accentAmber.withValues(alpha: 0.7),
                  label: 'RPM/100'),
              const SizedBox(width: 12),
              _LegendDot(
                  color: AppTheme.accentLime.withValues(alpha: 0.6),
                  label: 'Speed/10'),
            ],
          ),
          const SizedBox(height: 10),
          RepaintBoundary(
            child: SizedBox(height: 220, child: LineChart(_buildFuelChart())),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow({required bool tripRunning, required bool connected}) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: tripRunning
                  ? Colors.white12
                  : AppTheme.accentCyan,
              foregroundColor: tripRunning ? Colors.white54 : Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: tripRunning ? null : _startTrip,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('START TRIP',
                style: TextStyle(letterSpacing: 1, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              side: BorderSide(
                color: tripRunning
                    ? AppTheme.accentMagenta
                    : Colors.white24,
                width: 1.4,
              ),
              foregroundColor:
                  tripRunning ? AppTheme.accentMagenta : Colors.white54,
            ),
            onPressed: tripRunning ? _stopTrip : null,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('STOP',
                style: TextStyle(letterSpacing: 1, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 10),
        ConnectButton(
          connected: connected,
          tripRunning: tripRunning,
          onPressed: _connectDevice,
        ),
      ],
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
    final visiblePoints = [
      for (final p in _chartPoints)
        if (p.x >= viewStart) p,
    ];
    final safePoints = visiblePoints.isEmpty
        ? const [FlSpot(0, 0)]
        : visiblePoints;
    return _chartDataFor(
      points: safePoints,
      viewStart: viewStart,
      viewEnd: maxX,
    );
  }

  List<FlSpot> _filterVisible(List<FlSpot> points, double viewStart) {
    return [for (final p in points) if (p.x >= viewStart) p];
  }

  LineChartData _chartDataFor({
    required List<FlSpot> points,
    required double viewStart,
    required double viewEnd,
  }) {
    final adjustedEnd = viewEnd == viewStart ? viewStart + 1 : viewEnd;
    final rpmVisible = _filterVisible(_rpmChartPoints, viewStart);
    final speedVisible = _filterVisible(_speedChartPoints, viewStart);

    return LineChartData(
      minX: viewStart,
      maxX: adjustedEnd,
      minY: 0,
      clipData: const FlClipData.all(),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: points,
          isCurved: true,
          curveSmoothness: 0.25,
          color: AppTheme.accentCyan,
          barWidth: 2.5,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppTheme.accentCyan.withValues(alpha: 0.35),
                AppTheme.accentCyan.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
        if (rpmVisible.length > 1)
          LineChartBarData(
            spots: rpmVisible,
            isCurved: true,
            curveSmoothness: 0.2,
            color: AppTheme.accentAmber.withValues(alpha: 0.5),
            barWidth: 1.2,
            dotData: const FlDotData(show: false),
          ),
        if (speedVisible.length > 1)
          LineChartBarData(
            spots: speedVisible,
            isCurved: true,
            curveSmoothness: 0.2,
            color: AppTheme.accentLime.withValues(alpha: 0.4),
            barWidth: 1.2,
            dotData: const FlDotData(show: false),
          ),
      ],
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) => FlLine(
          color: Colors.white.withValues(alpha: 0.06),
          strokeWidth: 1,
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 10,
            reservedSize: 24,
            getTitlesWidget: (value, meta) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${value.toInt()}s',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 5,
            reservedSize: 32,
            getTitlesWidget: (value, meta) => Text(
              value.toStringAsFixed(0),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 10,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceDialog extends StatelessWidget {
  const _DeviceDialog({required this.devices});
  final List<BluetoothDevice> devices;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.surfaceDarkElevated,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(Icons.bluetooth_searching,
                      color: AppTheme.accentCyan),
                  const SizedBox(width: 10),
                  const Text(
                    'Select OBD Device',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: Colors.white.withValues(alpha: 0.08),
            ),
            Flexible(
              child: devices.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No paired devices found.\nPair your ELM327 in Bluetooth settings.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: devices.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                      itemBuilder: (_, index) {
                        final device = devices[index];
                        return ListTile(
                          leading: const Icon(Icons.bluetooth,
                              color: AppTheme.accentCyan),
                          title: Text(
                            device.name ?? 'Unknown',
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            device.address,
                            style: const TextStyle(color: Colors.white54),
                          ),
                          onTap: () => Navigator.of(context).pop(device),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}
