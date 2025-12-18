import 'dart:async';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

class ObdService {
  final Obd2Plugin obd2 = Obd2Plugin();

  Function(String)? onDataReceived;

  Timer? _pollTimer;
  bool _listenerReady = false;

  late final String _paramJson;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    await FlutterBluetoothSerial.instance.requestEnable();
    return await obd2.getNearbyPairedDevices;
  }

  Future<void> connect(BluetoothDevice device) async {
    await obd2.getConnection(
      device,
          (connection) async {
        print('Connected to ${device.address}');
        await _ensureListener();
        await _initObd(); // prepares config + stores _paramJson
      },
          (err) => print("Error: $err"),
    );
  }

  Future<void> _ensureListener() async {
    if (_listenerReady) return;

    await obd2.setOnDataReceived((command, response, requestCode) {
      // This is what your UI expects: "PID: VALUE"
      onDataReceived?.call('$command: $response');
      print("$command => $response");
    });

    _listenerReady = true;
  }

  Future<void> _initObd() async {
    const String configJson = '''[
      { "command": "AT Z",   "description": "", "status": true },
      { "command": "AT E0",  "description": "", "status": true },
      { "command": "AT SP 0","description": "", "status": true },
      { "command": "AT H0",  "description": "", "status": true },
      { "command": "AT L0",  "description": "", "status": true },
      { "command": "AT S0",  "description": "", "status": true },
      { "command": "01 00",  "description": "", "status": true }
    ]''';

    _paramJson = '''[
      {
        "PID": "01 0C",
        "length": 2,
        "title": "Engine RPM",
        "unit": "RPM",
        "description": "<double>, (( [0] * 256) + [1] ) / 4",
        "status": true
      },
      {
        "PID": "01 0B",
        "length": 1,
        "title": "MAP",
        "unit": "kPa",
        "description": "<int>, [0]",
        "status": true
      },
      {
        "PID": "01 0F",
        "length": 1,
        "title": "IAT",
        "unit": "°C",
        "description": "<int>, [0] - 40",
        "status": true
      }
    ]''';

    final waitMs = await obd2.configObdWithJSON(configJson);
    await Future.delayed(Duration(milliseconds: waitMs));
  }

  /// Call this when trip starts
  Future<void> startListening(Function(String) onData) async {
    onDataReceived = onData;
    await _ensureListener();

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final connected = await obd2.hasConnection;
      if (!connected) return;

      // This triggers responses for the PIDs above (then setOnDataReceived fires)
      await obd2.getParamsFromJSON(_paramJson);
    });
  }

  /// Call this when trip stops
  void stopListening(BluetoothDevice device) {
    _pollTimer?.cancel();
    _pollTimer = null;

    obd2.unpairWithDevice(device);
  }
}
