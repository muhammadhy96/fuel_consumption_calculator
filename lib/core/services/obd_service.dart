import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

import '../constants/obd_pids.dart';

class ObdService {
  final Obd2Plugin obd2 = Obd2Plugin();

  Function(String)? onDataReceived;

  Timer? _pollTimer;
  bool _listenerReady = false;
  final List<Completer<String?>> _pendingFrameRequests = [];
  Completer<void>? _readyCompleter;
  bool logTraffic = true;

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
      final payload = '$command: $response';
      _log('RECV $payload');
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

    _log('INIT config json: $configJson');
    _log('INIT params json: $_paramJson');
    final waitMs = await obd2.configObdWithJSON(configJson);
    await Future.delayed(Duration(milliseconds: waitMs));
  }

  Future<void> startListening(Function(String) onData) async {
    onDataReceived = onData;
    await _ensureListener();
    await _readyCompleter?.future;

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        _log('SEND getParamsFromJSON');
        await obd2.getParamsFromJSON(_paramJson);
      } catch (err) {
        print('OBD poll error: $err');
      }
    });
  }

  void stopListening(BluetoothDevice device) {
    _pollTimer?.cancel();
    _pollTimer = null;

    obd2.unpairWithDevice(device);
  }

  double fuelFlow(double rpm, double mapKpa, double iatKelvin) {
    if (iatKelvin <= 0) return 0;
    return obd2.fFuel(rpm, mapKpa, iatKelvin);
  }

  Future<String?> requestSingleFrame(
      {Duration timeout = const Duration(seconds: 3)}) async {
    await _ensureListener();
    await _readyCompleter?.future;
    final completer = Completer<String?>();
    _pendingFrameRequests.add(completer);
    _log('SEND single getParamsFromJSON');
    await obd2.getParamsFromJSON(_paramJson);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      _pendingFrameRequests.remove(completer);
    }
  }

  void _log(String message) {
    if (!logTraffic) return;
    final timestamp = DateTime.now().toIso8601String();
    debugPrint('[OBD][$timestamp] $message');
  }
}
