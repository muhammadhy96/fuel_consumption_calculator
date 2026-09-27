import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import '../core/services/obd_service.dart';
import '../core/utils/obd_frame_decoder.dart';

/// Where the current fuel-flow figure comes from.
enum FuelSource { direct, maf, absoluteLoad, speedDensity, none }

/// Holds live telemetry decoded from the ELM327 and exposes it to the UI.
///
/// Frame parsing lives in [ObdFrameDecoder] — a pure, hardware-free class — so
/// this provider only has to map decoded engineering values onto its public
/// fields. Sampling is driven by [ObdService.onCycleComplete]: [onFrame] fires
/// exactly once per completed poll cycle, never per response.
class ObdProvider extends ChangeNotifier {
  ObdProvider(this._obdService) {
    _obdService.onDisconnected = _handleServiceDisconnected;
    _obdService.onCycleComplete = _handleCycleComplete;
  }

  final ObdService _obdService;

  static const ObdFrameDecoder _decoder = ObdFrameDecoder();

  BluetoothDevice? _connectedDevice;
  bool _connected = false;
  bool _live = false;
  VoidCallback? onFrame;

  /// Fired when the transport drops while the provider was connected.
  /// [onFrame] is deliberately NOT cleared, so a successful reconnect resumes
  /// sampling with no further wiring.
  void Function()? onConnectionLost;

  // Live telemetry fields. Kept public for simple widget access.
  double rpm = 0;
  double mapKpa = 0;
  double speedKph = 0;
  double mafGramsPerSec = 0;
  double equivRatio = 1.0;
  double stftPercent = 0;
  double ltftPercent = 0;
  int? fuelSystemStatus;
  double? absoluteLoadPercent;
  bool _absoluteLoadSeen = false;
  double iatKelvin = 0;
  double coolantKelvin = 0;
  double throttlePercent = 0;
  double batteryVolts = 0;
  double? engineLoadPercent;
  double? fuelTankPercent;
  double? fuelRateMlPerSecDirect;
  double? baroKpa;
  String? lastRawMessage;
  DateTime? lastUpdate;
  DateTime? _lastLogTime;
  bool _disposed = false;
  bool _fuelRateProbed = false;
  int _framesDecoded = 0;

  /// A PID not decoded for this long is treated as unknown, so a stalled
  /// adapter or a switched-off ECU cannot keep feeding its last value into
  /// the trip.
  static const int freshnessWindowMs = 4000;

  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, int> _decodedAtMs = {};

  /// Throttle reading learned at idle (and lowered by any lower reading),
  /// used to recognise a closed throttle during deceleration fuel cut-off.
  double? _closedThrottlePercent;

  // Short rolling window of fuel-flow samples to smooth the UI readout.
  static const int _smoothingWindowSize = 8;
  final Queue<double> _smoothFuelWindow = Queue<double>();
  double _smoothFuelSum = 0;

  BluetoothDevice? get device => _connectedDevice;

  /// Last device we were connected to, retained across a drop so reconnect
  /// works.
  BluetoothDevice? get lastDevice => _connectedDevice;

  bool get connected => _connected;
  bool get live => _live;
  int get framesDecoded => _framesDecoded;
  Set<String> get supportedPids => _obdService.supportedPids;

  /// True while the transport is still batching PIDs into bulk mode-01
  /// requests; false once it has fallen back to one command per PID.
  bool get bulkModeActive => _obdService.bulkModeActive;

  /// ELM327 protocol digit currently in use, or null when unknown.
  String? get activeProtocol => _obdService.activeProtocol;

  /// Wall time of the last completed poll cycle, in milliseconds.
  int get lastCycleMillis => _obdService.lastCycleMillis;

  double get smoothedFuelMlPerSec {
    if (_smoothFuelWindow.isEmpty) return 0;
    return _smoothFuelSum / _smoothFuelWindow.length;
  }

  Future<List<BluetoothDevice>> getPairedDevices() =>
      _obdService.getPairedDevices();

  Future<void> connect(BluetoothDevice device) async {
    await _obdService.connect(device);
    if (_connectedDevice?.address != device.address) {
      _closedThrottlePercent = null;
    }
    _connectedDevice = device;
    _connected = true;
    _live = false;
    _fuelRateProbed = false;
    _decodedAtMs.clear();
    _notifyIfActive();
  }

  /// Re-dials [lastDevice] and restarts the live stream. Returns true on
  /// success. Safe to call repeatedly; no-op returning false when [lastDevice]
  /// is null.
  Future<bool> reconnect() async {
    if (_disposed) return false;
    final target = lastDevice;
    if (target == null) return false;
    try {
      await _obdService.connect(target);
      _connected = true;
      _live = false;
      _fuelRateProbed = false;
      _decodedAtMs.clear();
      _notifyIfActive();
      await startLive();
      return live;
    } catch (err) {
      _log('reconnect failed: $err');
      return false;
    }
  }

  Future<String?> verifyConnection() async {
    if (!_connected) return null;
    final sample = await _obdService.requestSingleFrame();
    if (sample != null && !sample.toUpperCase().contains('STOPPED')) {
      lastRawMessage = sample;
      lastUpdate = DateTime.now();
      _notifyIfActive();
      return sample;
    }
    return null;
  }

  Future<void> startLive() async {
    if (!_connected || _live) return;
    final started = await _obdService.startListening(_handleObdData);
    if (!started) {
      _handleServiceDisconnected();
      return;
    }
    _live = true;
    _notifyIfActive();
  }

  Future<void> stopLive() async {
    await _obdService.stopListening();
    _live = false;
    _resetTelemetry();
    onFrame = null;
    _notifyIfActive();
  }

  Future<void> disconnect() async {
    await _obdService.disconnect();
    _live = false;
    _connected = false;
    _connectedDevice = null;
    _resetTelemetry();
    onFrame = null;
    lastRawMessage = null;
    lastUpdate = null;
    _notifyIfActive();
  }

  bool _isFresh(String pid) {
    final at = _decodedAtMs[pid];
    return at != null && _clock.elapsedMilliseconds - at <= freshnessWindowMs;
  }

  /// True once PID 015E has reported a positive rate this session. From then
  /// on its readings, including 0 during fuel cut-off, are authoritative.
  bool get directFuelRateActive => _fuelRateProbed;

  FuelSource get fuelSource {
    if (!_connected) return FuelSource.none;
    if (_fuelRateProbed &&
        fuelRateMlPerSecDirect != null &&
        _isFresh('015E')) {
      return FuelSource.direct;
    }
    if (mafGramsPerSec > 0 && _isFresh('0110')) return FuelSource.maf;
    // Once 0143 has reported a positive value it is trusted, including the
    // near-zero readings it gives on overrun.
    if (_absoluteLoadSeen &&
        absoluteLoadPercent != null &&
        _isFresh('0143')) {
      return FuelSource.absoluteLoad;
    }
    if (mapKpa > 0 && _isFresh('010B')) return FuelSource.speedDensity;
    return FuelSource.none;
  }

  /// True when the inputs of the current sample were actually decoded within
  /// [freshnessWindowMs]: RPM, speed (once the car has reported it) and the
  /// fuel source. A stale sample must not be integrated into a trip.
  bool get telemetryFresh {
    if (!_isFresh('010C')) return false;
    if (_decodedAtMs.containsKey('010D') && !_isFresh('010D')) return false;
    return fuelSource != FuelSource.none;
  }

  double calculateFuelFlow({
    required double volumetricEfficiency,
    required double engineDisplacementLiters,
    required String fuelType,
  }) {
    final source = fuelSource;
    switch (source) {
      case FuelSource.none:
        return 0;
      case FuelSource.direct:
        return fuelRateMlPerSecDirect!;
      case FuelSource.maf:
      case FuelSource.absoluteLoad:
      case FuelSource.speedDensity:
        break;
    }
    final lambda = _isFresh('0144') ? equivRatio : null;
    final fuelCut = ObdService.isOverrunFuelCut(
      rpm: rpm,
      speedKph: _isFresh('010D') ? speedKph : 0,
      isDiesel: fuelType.toLowerCase() == 'diesel',
      throttlePercent: _isFresh('0111') ? throttlePercent : null,
      closedThrottlePercent: _closedThrottlePercent,
      mapKpa: _isFresh('010B') ? mapKpa : null,
      baroKpa: _isFresh('0133') ? baroKpa : null,
      lambda: lambda,
      fuelSystemStatus: _isFresh('0103') ? fuelSystemStatus : null,
    );
    if (fuelCut) return 0;
    final iat = iatKelvin > 0 && _isFresh('010F') ? iatKelvin : 293.15;
    return _obdService.fuelFlow(
      rpm,
      mapKpa,
      iat,
      volumetricEfficiency: volumetricEfficiency,
      engineDisplacementLiters: engineDisplacementLiters,
      fuelType: fuelType,
      equivRatio: lambda ?? 1.0,
      // Measured (MAF) or ECU-modelled (absolute load) air replaces the
      // speed-density estimate.
      mafGramsPerSec: switch (source) {
        FuelSource.maf => mafGramsPerSec,
        FuelSource.absoluteLoad => ObdService.airFromAbsoluteLoad(
            absoluteLoadPercent: absoluteLoadPercent!,
            rpm: rpm,
            engineDisplacementLiters: engineDisplacementLiters,
          ),
        _ => null,
      },
      stftPercent: _isFresh('0106') ? stftPercent : 0,
      ltftPercent: _isFresh('0107') ? ltftPercent : 0,
    );
  }

  /// Pushes a smoothed fuel sample into the rolling window and returns the
  /// smoothed value. The caller drives this from trip sampling.
  double pushFuelSample(double sample) {
    if (_smoothFuelWindow.length >= _smoothingWindowSize) {
      _smoothFuelSum -= _smoothFuelWindow.removeFirst();
    }
    _smoothFuelWindow.add(sample);
    _smoothFuelSum += sample;
    return smoothedFuelMlPerSec;
  }

  /// Applies one complete transport response. Deliberately does NOT notify —
  /// listeners are woken once per poll cycle from [_handleCycleComplete].
  void _handleObdData(String data) {
    if (_disposed) return;
    final trimmed = data.trim();
    if (trimmed.isEmpty) return;
    final upper = trimmed.toUpperCase();
    if (upper.contains('STOPPED') ||
        upper.contains('NO DATA') ||
        upper.contains('SEARCHING')) {
      return;
    }

    lastRawMessage = data;
    lastUpdate = DateTime.now();
    _framesDecoded += 1;

    final result = _decoder.decode(data);
    if (result.isEmpty) {
      _log('RAW nothing decodable in $data');
      return;
    }
    // Supported-PID bitmasks are owned by the service's PidSupport; the
    // provider only consumes telemetry.
    _applyValues(result.values);
  }

  /// Fired once per completed poll cycle by [ObdService]. This is the ONLY
  /// place [onFrame] fires, so trip sampling runs exactly once per cycle.
  void _handleCycleComplete() {
    if (_disposed) return;
    _learnClosedThrottle();
    onFrame?.call();
    _notifyIfActive();
  }

  void _learnClosedThrottle() {
    if (!_isFresh('0111') || !_isFresh('010C')) return;
    final closed = _closedThrottlePercent;
    final atIdle = rpm > 0 &&
        rpm < ObdService.fuelCutMinRpm &&
        _isFresh('010D') &&
        speedKph < 3;
    if (atIdle) {
      _closedThrottlePercent =
          closed == null || throttlePercent < closed ? throttlePercent : closed;
    } else if (closed != null && throttlePercent < closed) {
      // Drive-by-wire throttles close further on overrun than at idle.
      _closedThrottlePercent = throttlePercent;
    }
  }

  void _applyValues(Map<String, double> values) {
    final nowMs = _clock.elapsedMilliseconds;
    for (final entry in values.entries) {
      final value = entry.value;
      _decodedAtMs[entry.key] = nowMs;
      switch (entry.key) {
        case '010C':
          rpm = value;
          break;
        case '010D':
          speedKph = value;
          break;
        case '010B':
          mapKpa = value;
          break;
        case '0110':
          mafGramsPerSec = value;
          break;
        case '0104':
          engineLoadPercent = value;
          break;
        case '010F':
          iatKelvin = value;
          break;
        case '0105':
          coolantKelvin = value;
          break;
        case '0111':
          throttlePercent = value;
          break;
        case '0142':
          batteryVolts = value;
          break;
        case '012F':
          fuelTankPercent = value;
          break;
        case '0133':
          baroKpa = value;
          break;
        case '0144':
          equivRatio = value;
          break;
        case '0143':
          absoluteLoadPercent = value;
          if (value > 0) _absoluteLoadSeen = true;
          break;
        case '0103':
          fuelSystemStatus = value.toInt();
          break;
        case '0106':
          stftPercent = value;
          break;
        case '0107':
          ltftPercent = value;
          break;
        case '015E':
          fuelRateMlPerSecDirect = value;
          if (!_fuelRateProbed && value > 0) {
            _fuelRateProbed = true;
            _obdService.enableFuelRatePid();
          }
          break;
      }
    }
  }

  void _log(String message) {
    final now = DateTime.now();
    if (_lastLogTime != null &&
        now.difference(_lastLogTime!).inMilliseconds < 500) {
      return;
    }
    _lastLogTime = now;
    if (kDebugMode) {
      debugPrint('[OBD][${now.toIso8601String()}] $message');
    }
  }

  /// A mid-trip drop must leave [onFrame] and [lastDevice] intact so
  /// [reconnect] can resume sampling without any rewiring.
  void _handleServiceDisconnected() {
    _connected = false;
    _live = false;
    _resetTelemetry();
    _notifyIfActive();
    onConnectionLost?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    onFrame = null;
    onConnectionLost = null;
    _obdService.onDisconnected = null;
    _obdService.onCycleComplete = null;
    unawaited(_obdService.disconnect(notify: false));
    super.dispose();
  }

  void _notifyIfActive() {
    if (_disposed) return;
    notifyListeners();
  }

  void _resetTelemetry() {
    rpm = 0;
    mapKpa = 0;
    speedKph = 0;
    mafGramsPerSec = 0;
    equivRatio = 1.0;
    stftPercent = 0;
    ltftPercent = 0;
    fuelSystemStatus = null;
    absoluteLoadPercent = null;
    _absoluteLoadSeen = false;
    iatKelvin = 0;
    coolantKelvin = 0;
    throttlePercent = 0;
    batteryVolts = 0;
    engineLoadPercent = null;
    fuelTankPercent = null;
    fuelRateMlPerSecDirect = null;
    baroKpa = null;
    _decodedAtMs.clear();
    _smoothFuelWindow.clear();
    _smoothFuelSum = 0;
    _framesDecoded = 0;
  }
}
