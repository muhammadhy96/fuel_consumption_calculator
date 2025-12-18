import 'dart:async';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

import '../constants/obd_pids.dart';

class ObdService {
  final Obd2Plugin obd2 = Obd2Plugin();

  Function(String)? onDataReceived;

  Timer? _pollTimer;
  bool _listenerReady = false;
  final List<Completer<String?>> _pendingFrameRequests = [];

  late final String _paramJson;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    await FlutterBluetoothSerial.instance.requestEnable();
    return await obd2.getNearbyPairedDevices;
  }

  Future<void> connect(BluetoothDevice device) async {
    await obd2.getConnection(
      device,
      (connection) async {
        await _ensureListener();
        await _initObd();
      },
      (err) => print('Error: $err'),
    );
  }

  Future<void> _ensureListener() async {
    if (_listenerReady) return;

    await obd2.setOnDataReceived((command, response, requestCode) {
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

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final connected = await obd2.hasConnection;
      if (!connected) return;
      await obd2.getParamsFromJSON(_paramJson);
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
    final completer = Completer<String?>();
    _pendingFrameRequests.add(completer);
    await obd2.getParamsFromJSON(_paramJson);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      _pendingFrameRequests.remove(completer);
    }
  }
}
