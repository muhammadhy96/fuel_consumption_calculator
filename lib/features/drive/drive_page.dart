import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/services/trip_foreground_service.dart';
import '../../core/theme/app_theme.dart';
import '../../features/drive/connect_button.dart';
import '../../features/drive/fuel_chart_card.dart';
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

  /// Back-off schedule for the automatic reconnect loop.
  static const List<Duration> _reconnectBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 6),
    Duration(seconds: 8),
    Duration(seconds: 10),
  ];

  double _fuelFlow = 0;
  double _timeSeconds = 0;
  LiveTripStats _tripStats = LiveTripStats.zero;
  late final FuelChartController _chartController = FuelChartController();

  /// Built once and reused so the 100 ms statistics [setState] hands the
  /// element tree an identical widget instance — the chart subtree is then
  /// skipped entirely instead of being rebuilt and re-laid-out.
  late final Widget _chartCard = FuelChartCard(controller: _chartController);
  int _lastChartUpdateMs = 0;
  int _lastUiUpdateMs = 0;
  CarProfile? _activeProfile;

  /// Bumped on every trip start/stop so an in-flight reconnect loop from a
  /// previous trip can detect that it is stale and bail out.
  int _tripSession = 0;

  /// Trip session that currently owns the reconnect loop. Scoped per session
  /// rather than a bare bool so a loop left sleeping by a previous trip cannot
  /// swallow the next trip's connection-lost event (it is edge-triggered, so a
  /// swallowed event is never retried).
  int? _reconnectingSession;

  /// Captured in [didChangeDependencies] so [dispose] never has to touch
  /// `context` — the element is defunct by then and a provider lookup there
  /// would strand every cleanup line after it.
  ObdProvider? _obdRef;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _obdRef = context.read<ObdProvider>();
  }

  @override
  void dispose() {
    _sampleStopwatch.stop();
    // Bumping the session first makes any in-flight reconnect loop bail out
    // (and undo a link it may have just re-established) instead of resurrecting
    // the poll loop behind us.
    _tripSession += 1;
    _reconnectingSession = null;
    // Local teardown runs before anything that could fail, so the foreground
    // notification and the chart controller are always released.
    unawaited(TripForegroundService.stop());
    _chartController.dispose();
    final obd = _obdRef;
    if (obd != null) {
      obd.onFrame = null;
      obd.onConnectionLost = null;
      unawaited(obd.stopLive());
    }
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<bool> _requestPermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    // We no longer run a discovery scan, so location is not required on any
    // API level for this flow. Ask for it (and for notifications, needed by
    // the foreground-service notification on API 33+) without blocking.
    unawaited(_requestOptionalPermissions());
    final granted = scan.isGranted && connect.isGranted;
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth permissions are required.'),
        ),
      );
    }
    return granted;
  }

  /// Best-effort permissions. Their outcome never gates connecting.
  Future<void> _requestOptionalPermissions() async {
    try {
      await Permission.location.request();
      await Permission.notification.request();
    } catch (err) {
      if (kDebugMode) {
        debugPrint('[DrivePage] optional permission request failed: $err');
      }
    }
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
    _tripSession += 1;

    _chartController.clear();
    setState(() {
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
    obd.onConnectionLost = _handleConnectionLost;
    unawaited(TripForegroundService.start(profileName: profile.name));
  }

  /// Called by [ObdProvider] when the transport drops mid-trip.
  void _handleConnectionLost() {
    if (!mounted) return;
    unawaited(_runReconnectLoop());
  }

  /// Retries the OBD link with a widening back-off, keeping the trip alive.
  ///
  /// Re-entrancy guarded, and abandoned as soon as the widget is gone or the
  /// trip it was started for has ended.
  Future<void> _runReconnectLoop() async {
    final session = _tripSession;
    // Guard per session, not globally: a loop still sleeping on a back-off from
    // an earlier trip must not cause this trip's event to be dropped.
    if (_reconnectingSession == session) return;
    _reconnectingSession = session;
    final obd = _obdRef;
    if (obd == null) return;
    try {
      _showSnack('OBD link lost — reconnecting…');
      for (final delay in _reconnectBackoff) {
        await Future<void>.delayed(delay);
        if (_isStaleReconnect(session)) return;
        var reconnected = false;
        try {
          reconnected = await obd.reconnect();
        } catch (err) {
          if (kDebugMode) {
            debugPrint('[DrivePage] reconnect attempt failed: $err');
          }
        }
        // reconnect() can outlive the trip: it re-dials AND restarts the poll
        // loop, so if the trip ended while we were awaiting it we have to undo
        // that here — nothing else will, and the loop would poll forever.
        if (_isStaleReconnect(session)) {
          if (reconnected) unawaited(obd.stopLive());
          return;
        }
        if (reconnected) {
          _showSnack('Reconnected');
          return;
        }
      }
      _showSnack('Could not reconnect — trip is still recording elapsed time.');
    } finally {
      if (_reconnectingSession == session) _reconnectingSession = null;
    }
  }

  /// True once the trip this reconnect loop was started for has ended, or the
  /// page is gone.
  bool _isStaleReconnect(int session) =>
      !mounted || session != _tripSession || _activeProfile == null;

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

    if (shouldUpdateChart) {
      _lastChartUpdateMs = nowMs;
      // The chart owns its own series and listens to the controller, so this
      // does not rebuild the rest of the drive screen.
      _chartController.addPoint(_timeSeconds, smoothFuel);
    }
    if (!shouldUpdateUi) return;

    final avgConsumption = _distanceKm > 0
        ? (_totalFuelMl / 1000) / _distanceKm * 100
        : 0.0;

    final instantConsumption = _computeInstantConsumption();
    final costEstimate =
        _fuelPricePerLiter > 0 ? (_totalFuelMl / 1000) * _fuelPricePerLiter : 0.0;
    final ecoScore = _computeEcoScore(obd.rpm, avgConsumption);

    setState(() {
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
    _tripSession += 1;
    final obd = context.read<ObdProvider>();
    final profileProvider = context.read<ProfileProvider>();
    final tripProvider = context.read<TripProvider>();
    obd.onFrame = null;
    obd.onConnectionLost = null;
    await TripForegroundService.stop();
    try {
      await obd.stopLive();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stop live OBD stream: $err')),
        );
      }
    }
    // Same fallback as build(): a profile deleted mid-trip must not cost the
    // user their trip summary.
    final profile = profileProvider.selectedProfile ?? _activeProfile;
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
    // Fall back to the trip's own profile: if the selected profile is deleted
    // mid-trip we must keep rendering the dashboard, otherwise the placeholder
    // replaces the STOP button and the timer, poll loop and foreground
    // notification are left running with no way to end them.
    final profile =
        context.watch<ProfileProvider>().selectedProfile ?? _activeProfile;
    final tripRunning = context.select<TripProvider, bool>((t) => t.running);
    final connected = context.select<ObdProvider, bool>((o) => o.connected);
    if (profile == null) {
      return _buildNoProfile(context);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LiveDashboard(
            profile: profile,
            fuelFlow: _fuelFlow,
            tripStats: _tripStats,
          ),
          const SizedBox(height: 18),
          _chartCard,
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

