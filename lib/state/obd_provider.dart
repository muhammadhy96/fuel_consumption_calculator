import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import '../core/constants/obd_pids.dart';
import '../core/services/obd_service.dart';
import '../core/utils/pid_support.dart';

/// Holds live telemetry decoded from the ELM327 and exposes it to the UI.
///
/// Parses responses from bulk multi-PID commands shaped like
/// `41 0C AA BB 0D XX 0B YY 10 ZZ ZZ 04 WW 0F VV`, i.e. one mode byte followed
/// by repeated `PID + N data bytes` groups. This single-pass parser replaces
/// the legacy per-PID switch-case and decouples parsing from the command
/// that was sent — so if the ECU echoes PIDs out of order, we still decode.
class ObdProvider extends ChangeNotifier {
  ObdProvider(this._obdService) {
    _obdService.onDisconnected = _handleServiceDisconnected;
  }

  final ObdService _obdService;

  BluetoothDevice? _connectedDevice;
  bool _connected = false;
  bool _live = false;
  VoidCallback? onFrame;

  // Live telemetry fields. Kept public for simple widget access.
  double rpm = 0;
  double mapKpa = 0;
  double speedKph = 0;
  double mafGramsPerSec = 0;
  double equivRatio = 1.0;
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
  final Set<String> _cyclePidsSeen = <String>{};
  bool _disposed = false;
  bool _fuelRateProbed = false;
  int _framesDecoded = 0;
  final PidSupport _pidSupport = PidSupport();

  // Short rolling window of fuel-flow samples to smooth the UI readout.
  static const int _smoothingWindowSize = 8;
  final Queue<double> _smoothFuelWindow = Queue<double>();
  double _smoothFuelSum = 0;

  static const Set<String> _cycleCandidatePids = {
    '010C', '010D', '010B', '0110', '0104', '010F',
  };

  BluetoothDevice? get device => _connectedDevice;
  bool get connected => _connected;
  bool get live => _live;
  int get framesDecoded => _framesDecoded;
  Set<String> get supportedPids => _pidSupport.supportedPids;

  double get smoothedFuelMlPerSec {
    if (_smoothFuelWindow.isEmpty) return 0;
    return _smoothFuelSum / _smoothFuelWindow.length;
  }

  Future<List<BluetoothDevice>> getPairedDevices() =>
      _obdService.getPairedDevices();

  Future<void> connect(BluetoothDevice device) async {
    await _obdService.connect(device);
    _connectedDevice = device;
    _connected = true;
    _live = false;
    _cyclePidsSeen.clear();
    _fuelRateProbed = false;
    _notifyIfActive();
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
    _cyclePidsSeen.clear();
    _resetTelemetry();
    onFrame = null;
    _notifyIfActive();
  }

  Future<void> disconnect() async {
    await _obdService.disconnect();
    _live = false;
    _connected = false;
    _connectedDevice = null;
    _cyclePidsSeen.clear();
    _resetTelemetry();
    onFrame = null;
    lastRawMessage = null;
    lastUpdate = null;
    _notifyIfActive();
  }

  double calculateFuelFlow({
    required double volumetricEfficiency,
    required double engineDisplacementLiters,
    double equivRatio = 1.0,
  }) {
    if (fuelRateMlPerSecDirect != null && fuelRateMlPerSecDirect! > 0) {
      return fuelRateMlPerSecDirect!;
    }
    if (!_connected) return 0;
    final vePercent = engineLoadPercent ?? volumetricEfficiency;
    final iat = iatKelvin > 0 ? iatKelvin : 293.15;
    final maf = mafGramsPerSec > 0 ? mafGramsPerSec : null;
    return _obdService.fuelFlow(
      rpm,
      mapKpa,
      iat,
      volumetricEfficiency: vePercent,
      engineDisplacementLiters: engineDisplacementLiters,
      equivRatio: equivRatio,
      mafGramsPerSec: maf,
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

    final colonIndex = data.indexOf(':');
    final payload = colonIndex >= 0 ? data.substring(colonIndex + 1) : data;
    final bytes = _parseHexBytes(payload);
    if (bytes.isEmpty) {
      _log('RAW no bytes in $data');
      return;
    }

    final seen = <String>{};
    _decodeMultiPidFrame(bytes, seen);
    for (final pid in seen) {
      _markPidForCycle(pid);
    }
    _notifyIfActive();
  }

  /// Decodes one or more `PID + dataBytes` groups packed in a single response.
  ///
  /// Mode 01 responses begin with 0x41. There can be multiple 0x41 blocks in
  /// a multi-frame reply; each block is followed by repeating `pid + N` groups
  /// until the next 0x41 or the end of the payload.
  void _decodeMultiPidFrame(List<int> bytes, Set<String> seen) {
    var i = 0;
    while (i < bytes.length) {
      final modeByte = bytes[i];

      if (modeByte == 0x41) {
        i += 1;
        // Supported-PID bitmask responses (01 00, 01 20, 01 40) carry
        // exactly 4 data bytes and we should not try to decode them as
        // telemetry PIDs.
        if (i < bytes.length &&
            (bytes[i] == 0x00 || bytes[i] == 0x20 || bytes[i] == 0x40) &&
            i + 5 <= bytes.length) {
          _pidSupport.parseRange(bytes[i], bytes.sublist(i + 1, i + 5));
          _log('PID support bitmask parsed for range 0x${bytes[i].toRadixString(16)}');
          i += 5;
          continue;
        }
        // Walk the inner run until we either exhaust the stream or bump into
        // another 0x41 header which marks the next frame.
        while (i < bytes.length && bytes[i] != 0x41) {
          final pidByte = bytes[i];
          final pidKey = '01${pidByte.toRadixString(16).padLeft(2, '0')}'
              .toUpperCase();
          final length = pidByteLength[pidKey];
          if (length == null || i + 1 + length > bytes.length) {
            i = bytes.length;
            break;
          }
          final payload = bytes.sublist(i + 1, i + 1 + length);
          _updatePid(pidKey, payload);
          seen.add(pidKey);
          i += 1 + length;
        }
        continue;
      }

      if (modeByte == 0x62 && i + 2 < bytes.length) {
        // Mode 22 response: 62 PIDHI PIDLO DATA...
        final pidKey = '22'
            '${bytes[i + 1].toRadixString(16).padLeft(2, '0')}'
            '${bytes[i + 2].toRadixString(16).padLeft(2, '0')}'.toUpperCase();
        // Only MAF extended is handled today.
        if ((pidKey == '220101' || pidKey == '2200101') &&
            i + 4 < bytes.length) {
          mafGramsPerSec = ((bytes[i + 3] * 256) + bytes[i + 4]) / 100;
          seen.add('0110');
          _log('EXT MAF=$mafGramsPerSec');
          i += 5;
          continue;
        }
        i += 3;
        continue;
      }

      // Unknown byte — advance and keep scanning. This keeps us robust
      // against CAN header garbage or stray bytes the plugin may leave in.
      i += 1;
    }
  }

  void _updatePid(String pid, List<int> data) {
    switch (pid) {
      case '010C':
        if (data.length >= 2) rpm = ((data[0] * 256) + data[1]) / 4;
        break;
      case '010D':
        speedKph = data[0].toDouble();
        break;
      case '010B':
        mapKpa = data[0].toDouble();
        break;
      case '0110':
        if (data.length >= 2) {
          mafGramsPerSec = ((data[0] * 256) + data[1]) / 100;
        }
        break;
      case '0104':
        engineLoadPercent = (data[0] * 100) / 255;
        break;
      case '010F':
        iatKelvin = (data[0] - 40) + 273.15;
        break;
      case '0105':
        coolantKelvin = (data[0] - 40) + 273.15;
        break;
      case '0111':
        throttlePercent = (data[0] * 100) / 255;
        break;
      case '0142':
        if (data.length >= 2) {
          batteryVolts = ((data[0] * 256) + data[1]) / 1000;
        }
        break;
      case '012F':
        fuelTankPercent = (data[0] * 100) / 255;
        break;
      case '0133':
        baroKpa = data[0].toDouble();
        break;
      case '0144':
        if (data.length >= 2) {
          equivRatio = ((data[0] * 256) + data[1]) / 32768;
        }
        break;
      case '015E':
        if (data.length >= 2) {
          final lph = ((data[0] * 256) + data[1]) / 20;
          fuelRateMlPerSecDirect = (lph * 1000) / 3600;
          if (!_fuelRateProbed && (fuelRateMlPerSecDirect ?? 0) > 0) {
            _fuelRateProbed = true;
            _obdService.enableFuelRatePid();
          }
        }
        break;
    }
  }

  List<int> _parseHexBytes(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final bytes = <int>[];
    for (var i = 0; i + 1 < cleaned.length; i += 2) {
      final value = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (value != null) bytes.add(value);
    }
    return bytes;
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

  void _handleServiceDisconnected() {
    _connected = false;
    _live = false;
    _cyclePidsSeen.clear();
    _resetTelemetry();
    onFrame = null;
    _notifyIfActive();
  }

  void _markPidForCycle(String pid) {
    if (!_cycleCandidatePids.contains(pid)) return;
    _cyclePidsSeen.add(pid);
    if (_isCycleReadyForSampling()) {
      _cyclePidsSeen.clear();
      onFrame?.call();
    }
  }

  bool _isCycleReadyForSampling() {
    final hasRpm = _cyclePidsSeen.contains('010C');
    final hasFuelSignal = _cyclePidsSeen.contains('0110') ||
        _cyclePidsSeen.contains('010B');
    return hasRpm && hasFuelSignal;
  }

  /// Reads stored DTCs (mode 03) and decodes them into standard OBD-II codes.
  Future<List<String>> readDtc() async {
    final raw = await _obdService.requestDtcRaw();
    if (raw == null) return [];
    return _decodeDtcResponse(raw);
  }

  Future<void> clearDtc() async {
    await _obdService.clearDtc();
  }

  List<String> _decodeDtcResponse(String raw) {
    final bytes = _parseHexBytes(raw);
    // Mode 03 response: 43 followed by pairs of bytes per DTC.
    final codes = <String>[];
    var i = 0;
    while (i < bytes.length) {
      if (bytes[i] == 0x43) {
        i += 1;
        continue;
      }
      if (i + 1 >= bytes.length) break;
      final a = bytes[i];
      final b = bytes[i + 1];
      if (a == 0 && b == 0) {
        i += 2;
        continue;
      }
      final category = (a >> 6) & 0x03;
      final prefix = const ['P', 'C', 'B', 'U'][category];
      final digit1 = (a >> 4) & 0x03;
      final digit2 = a & 0x0F;
      final digit3 = (b >> 4) & 0x0F;
      final digit4 = b & 0x0F;
      codes.add('$prefix$digit1'
          '${digit2.toRadixString(16).toUpperCase()}'
          '${digit3.toRadixString(16).toUpperCase()}'
          '${digit4.toRadixString(16).toUpperCase()}');
      i += 2;
    }
    return codes;
  }

  @override
  void dispose() {
    _disposed = true;
    onFrame = null;
    _obdService.onDisconnected = null;
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
    iatKelvin = 0;
    coolantKelvin = 0;
    throttlePercent = 0;
    batteryVolts = 0;
    engineLoadPercent = null;
    fuelTankPercent = null;
    fuelRateMlPerSecDirect = null;
    baroKpa = null;
    _smoothFuelWindow.clear();
    _smoothFuelSum = 0;
    _framesDecoded = 0;
  }
}
