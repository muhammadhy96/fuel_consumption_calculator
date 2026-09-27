import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/services/obd_transport.dart';
import '../../core/services/trip_foreground_service.dart';
import '../../core/theme/app_theme.dart';
import '../../features/drive/confirm_profile_sheet.dart';
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

  /// Requests every permission one at a time, before the Bluetooth plugin is
  /// called: the plugin makes its own location request, and two requests in
  /// flight at once make Android drop one of them.
  Future<bool> _requestPermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    if (!scan.isGranted || !connect.isGranted) {
      _showPermissionProblem(
        'Bluetooth permission is needed to talk to the OBD adapter.',
        permanentlyDenied:
            scan.isPermanentlyDenied || connect.isPermanentlyDenied,
      );
      return false;
    }
    // The Bluetooth plugin refuses to list paired devices without location
    // access on every Android version, even though it never scans.
    final location = await Permission.location.request();
    if (!location.isGranted) {
      _showPermissionProblem(
        'Location permission is needed to list paired Bluetooth devices. '
        'The app does not use your location.',
        permanentlyDenied: location.isPermanentlyDenied,
      );
      return false;
    }
    await _requestNotificationPermission();
    return true;
  }

  /// Only the trip notification depends on this, so the answer is not
  /// checked.
  Future<void> _requestNotificationPermission() async {
    try {
      await Permission.notification.request();
    } catch (err) {
      if (kDebugMode) {
        debugPrint('[DrivePage] notification permission request failed: $err');
      }
    }
  }

  void _showPermissionProblem(
    String message, {
    required bool permanentlyDenied,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          permanentlyDenied ? '$message Allow it in app settings.' : message,
        ),
        action: permanentlyDenied
            ? SnackBarAction(
                label: 'Settings',
                onPressed: () => unawaited(openAppSettings()),
              )
            : null,
      ),
    );
  }

  Future<bool> _connectDevice() async {
    final type = await showDialog<ObdConnectionType>(
      context: context,
      builder: (_) => const _ConnectionTypeDialog(),
    );
    if (type == null || !mounted) return false;
    final device = type == ObdConnectionType.wifi
        ? await _pickWifiDevice()
        : await _pickBluetoothDevice();
    if (device == null || !mounted) return false;
    final obd = context.read<ObdProvider>();
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
                  : 'Connected to ${device.name}, waiting for data...',
            ),
          ),
        );
      }
      return true;
    } catch (err) {
      if (mounted) {
        final msg = _classifyObdError(err, device.type);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
      return false;
    }
  }

  Future<ObdDevice?> _pickWifiDevice() async {
    await _requestNotificationPermission();
    if (!mounted) return null;
    final last = await context.read<ObdProvider>().lastWifiDevice();
    if (!mounted) return null;
    return showDialog<ObdDevice>(
      context: context,
      builder: (_) => _WifiDeviceDialog(initial: last),
    );
  }

  Future<ObdDevice?> _pickBluetoothDevice() async {
    if (!await _requestPermissions()) return null;
    if (!mounted) return null;
    final obd = context.read<ObdProvider>();
    List<BluetoothDevice> devices;
    try {
      devices = await obd.getPairedDevices();
    } catch (err) {
      if (mounted) {
        final message = err.toString().contains('no_permissions')
            ? 'Location permission is needed to list paired Bluetooth devices.'
            : 'Failed to load paired devices: $err';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
      return null;
    }
    if (!mounted) return null;
    final device = await showDialog<BluetoothDevice>(
      context: context,
      builder: (_) => _DeviceDialog(devices: devices),
    );
    return device == null ? null : ObdDevice.bluetooth(device);
  }

  Future<void> _startTrip() async {
    final tripProvider = context.read<TripProvider>();
    var selected = context.read<ProfileProvider>().selectedProfile;
    if (selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a profile first.')),
      );
      return;
    }
    // With more than one car on file the selection carries over from the last
    // session, so make the driver confirm it before anything is recorded — a
    // trip cannot be moved to another profile once it has started.
    if (shouldConfirmProfile(context)) {
      final confirmed = await showConfirmProfileSheet(context);
      if (!mounted || confirmed == null) return;
      selected = confirmed;
    }
    final CarProfile profile = selected;
    final obd = context.read<ObdProvider>();
    if (!obd.connected) {
      final connected = await _connectDevice();
      if (!connected) return;
    }
    await obd.startLive();
    if (!mounted) return;
    // Applied only now, so a cancelled device dialog or a failed connect above
    // leaves the app's selected car exactly as the driver left it. From here on
    // the dashboard header and the recorded trip name the same profile.
    context.read<ProfileProvider>().selectProfile(profile);
    tripProvider.startTrip(profile);
    _activeProfile = profile;
    _tripSession += 1;

    _chartController.clear();
    setState(() {
      _fuelFlow = 0;
      _timeSeconds = 0;
      _lastChartUpdateMs = 0;
      _lastUiUpdateMs = 0;
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

  int _computeEcoScore(double rpm, double avgL100, double distanceKm) {
    if (distanceKm < 0.1) return 0;
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

  String _classifyObdError(Object err, ObdConnectionType type) {
    final msg = err.toString().toLowerCase();
    if (type == ObdConnectionType.wifi &&
        (err is SocketException || err is TimeoutException)) {
      return 'Cannot reach the Wi-Fi adapter. Join its Wi-Fi network and '
          'check the IP address and port.';
    }
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
    // A cycle in which the adapter or the ECU stopped answering carries only
    // the last known values. Recording them would add distance and fuel that
    // never happened; the trip integrator bridges or skips the gap instead.
    if (!obd.telemetryFresh) return;
    final rawFuel = obd.calculateFuelFlow(
      volumetricEfficiency: profile.volumetricEfficiency,
      engineDisplacementLiters: profile.effectiveDisplacementLiters,
      fuelType: profile.fuelType,
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
      stftPercent: obd.stftPercent,
      ltftPercent: obd.ltftPercent,
      fuelSystemStatus: obd.fuelSystemStatus ?? 0,
      absoluteLoadPercent: obd.absoluteLoadPercent ?? 0,
    );
    trip.addSample(sample);

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

    // The same totals the saved trip will carry.
    final totalFuelMl = trip.totalFuelMl;
    final distanceKm = trip.distanceKm;
    final avgConsumption =
        distanceKm > 0 ? (totalFuelMl / 1000) / distanceKm * 100 : 0.0;

    final instantConsumption = _computeInstantConsumption();
    final costEstimate =
        _fuelPricePerLiter > 0 ? (totalFuelMl / 1000) * _fuelPricePerLiter : 0.0;
    final ecoScore = _computeEcoScore(obd.rpm, avgConsumption, distanceKm);

    setState(() {
      _fuelFlow = smoothFuel;
      _lastUiUpdateMs = nowMs;
      _tripStats = LiveTripStats(
        totalFuelMl: totalFuelMl,
        distanceKm: distanceKm,
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
    // The car the trip was recorded for, not whatever is selected now.
    final profile = _activeProfile ?? profileProvider.selectedProfile;
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
    // While recording, the header always names the car the trip is computed
    // for, whatever is selected elsewhere.
    final selected = context.watch<ProfileProvider>().selectedProfile;
    final tripRunning = context.select<TripProvider, bool>((t) => t.running);
    final profile = tripRunning
        ? (_activeProfile ?? selected)
        : (selected ?? _activeProfile);
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


class _ConnectionTypeDialog extends StatelessWidget {
  const _ConnectionTypeDialog();

  @override
  Widget build(BuildContext context) {
    Widget option(
      ObdConnectionType type,
      IconData icon,
      String title,
      String subtitle,
    ) =>
        ListTile(
          leading: Icon(icon, color: AppTheme.accentCyan),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          subtitle:
              Text(subtitle, style: const TextStyle(color: Colors.white54)),
          onTap: () => Navigator.of(context).pop(type),
        );

    return Dialog(
      backgroundColor: AppTheme.surfaceDarkElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(Icons.cable, color: AppTheme.accentCyan),
                  SizedBox(width: 10),
                  Text(
                    'Connect OBD Adapter',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            option(ObdConnectionType.bluetooth, Icons.bluetooth, 'Bluetooth',
                'Paired ELM327 adapter'),
            option(ObdConnectionType.wifi, Icons.wifi, 'Wi-Fi',
                'ELM327 on its own Wi-Fi network'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _WifiDeviceDialog extends StatefulWidget {
  const _WifiDeviceDialog({required this.initial});

  final ObdDevice initial;

  @override
  State<_WifiDeviceDialog> createState() => _WifiDeviceDialogState();
}

class _WifiDeviceDialogState extends State<_WifiDeviceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _host =
      TextEditingController(text: widget.initial.address);
  late final TextEditingController _port =
      TextEditingController(text: '${widget.initial.port}');

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      ObdDevice.wifi(host: _host.text.trim(), port: int.parse(_port.text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const fieldStyle = TextStyle(color: Colors.white);
    return AlertDialog(
      backgroundColor: AppTheme.surfaceDarkElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text(
        'Wi-Fi OBD Adapter',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Join the Wi-Fi network of the adapter first. Most adapters '
              'use ${ObdDevice.defaultWifiHost}:${ObdDevice.defaultWifiPort}.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _host,
              style: fieldStyle,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'IP address'),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Enter the adapter IP' : null,
            ),
            TextFormField(
              controller: _port,
              style: fieldStyle,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
              validator: (v) {
                final port = int.tryParse(v ?? '');
                return port == null || port < 1 || port > 65535
                    ? 'Enter a port between 1 and 65535'
                    : null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Connect')),
      ],
    );
  }
}
