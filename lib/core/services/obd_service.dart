import 'dart:async';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

import '../constants/obd_pids.dart';

class ObdService {
  final Obd2Plugin obd2 = Obd2Plugin();

  Function(String)? onDataReceived;

  bool _connected = false;
  bool _listenerReady = false;
  bool _isPolling = false;
  final List<Completer<String?>> _pendingFrameRequests = [];
  Completer<void>? _readyCompleter;
  Completer<void>? _pollResponseCompleter;
  int _pollErrorStreak = 0;
  Future<void>? _pollLoopFuture;

  late final String _paramJson;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    await FlutterBluetoothSerial.instance.requestEnable();
    return await obd2.getNearbyPairedDevices;
  }

  Future<void> connect(BluetoothDevice device) async {
    _readyCompleter = Completer<void>();
    await obd2.getConnection(
      device,
      (connection) async {
        try {
          await _ensureListener();
          await _initObd();
          _connected = true;
          if (!(_readyCompleter?.isCompleted ?? true)) {
            _readyCompleter?.complete();
          }
        } catch (err) {
          if (!(_readyCompleter?.isCompleted ?? true)) {
            _readyCompleter?.completeError(err);
          }
        }
      },
      (err) {
        _connected = false;
        _isPolling = false;
        if (!(_readyCompleter?.isCompleted ?? true)) {
          _readyCompleter?.completeError(err);
        }
      },
    );
    await _readyCompleter?.future.timeout(const Duration(seconds: 10));
  }

  Future<void> _ensureListener() async {
    if (_listenerReady) return;

    await obd2.setOnDataReceived((command, response, requestCode) {
      _completePollResponse();
      final payload = '$command: $response';
      if (_pendingFrameRequests.isNotEmpty) {
        final completer = _pendingFrameRequests.removeAt(0);
        if (!completer.isCompleted) {
          completer.complete(payload);
        }
      }
      onDataReceived?.call(payload);
    });

    _listenerReady = true;
  }

  Future<void> _initObd() async {
    const String configJson = obdInitCommands;

    _paramJson = obdParamConfig;

    final waitMs = await obd2.configObdWithJSON(configJson);
    await Future.delayed(Duration(milliseconds: waitMs));
  }

  Future<void> startListening(Function(String) onData) async {
    onDataReceived = onData;
    await _ensureListener();
    await _readyCompleter?.future;

    if (!_connected) return;
    if (_isPolling) return;
    _isPolling = true;
    _pollLoopFuture = _pollLoop().catchError((_) {});
  }

  Future<void> stopListening(BluetoothDevice device) async {
    _isPolling = false;
    _connected = false;
    _completePollResponse();
    final pendingLoop = _pollLoopFuture;
    _pollLoopFuture = null;
    try {
      await pendingLoop;
    } catch (_) {
      // Ignore loop errors during shutdown.
    }
    try {
      obd2.unpairWithDevice(device);
    } catch (_) {
      // Ignore disconnect errors.
    }
  }

  Future<void> _pollLoop() async {
    while (_isPolling && _connected) {
      try {
        if (!_connected) break;
        _pollResponseCompleter = Completer<void>();
        await obd2.getParamsFromJSON(_paramJson);
        _pollErrorStreak = 0;

        final waitForResponse =
            _pollResponseCompleter?.future ?? Future<void>.value();
        await Future.any([
          waitForResponse,
          Future.delayed(const Duration(milliseconds: 40)),
        ]);
        _pollResponseCompleter = null;
      } catch (err) {
        _pollErrorStreak += 1;
        print('OBD poll error: $err');
        await Future.delayed(const Duration(milliseconds: 200));
        if (_pollErrorStreak >= 1) {
          // On first error, stop to avoid writing to a closed socket.
          _isPolling = false;
          _connected = false;
          _completePollResponse();
          break;
        }
      }
    }
  }

  void _completePollResponse() {
    final completer = _pollResponseCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _pollResponseCompleter = null;
  }

  double fuelFlow(
    double rpm,
    double mapKpa,
    double iatKelvin, {
    required double volumetricEfficiency,
    required double engineDisplacementLiters,
    double equivRatio = 1.0,
    double? mafGramsPerSec,
  }) {
    if (rpm <= 0) return 0;
    final actualAfr = 14.7 * (equivRatio <= 0 ? 1.0 : equivRatio);

    final gramsOfAir = mafGramsPerSec ??
        _calcGramsOfAir(
          rpm: rpm,
          mapKpa: mapKpa,
          iatKelvin: iatKelvin,
          volumetricEfficiency: volumetricEfficiency,
          engineDisplacementLiters: engineDisplacementLiters,
        );
    final gramsOfFuel = gramsOfAir / actualAfr;
    return (gramsOfFuel / 745) * 1000;
  }

  double _calcGramsOfAir({
    required double rpm,
    required double mapKpa,
    required double iatKelvin,
    required double volumetricEfficiency,
    required double engineDisplacementLiters,
  }) {
    if (iatKelvin <= 0 || mapKpa <= 0) return 0;
    const double molarMassAir = 28.97; // g/mol
    const double gasConstant = 8.314; // kPa*L/(mol*K)
    final imap = (rpm * mapKpa) / (iatKelvin * 2);
    final gramsOfAir = (imap / 60) *
        (volumetricEfficiency / 100) *
        engineDisplacementLiters *
        molarMassAir /
        gasConstant;
    return gramsOfAir;
  }

  Future<String?> requestSingleFrame(
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (!_connected) return null;
    await _ensureListener();
    await _readyCompleter?.future;
    final completer = Completer<String?>();
    _pendingFrameRequests.add(completer);
    try {
      await obd2.getParamsFromJSON(_paramJson);
    } catch (err) {
      _pendingFrameRequests.remove(completer);
      return null;
    }
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      _pendingFrameRequests.remove(completer);
    }
  }

}
