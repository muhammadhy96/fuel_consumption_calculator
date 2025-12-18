import 'dart:async';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

class ObdService {
  final Obd2Plugin obd2 = Obd2Plugin();
  StreamSubscription? _dataSubscription;
  Function(String)? onDataReceived;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    await FlutterBluetoothSerial.instance.requestEnable();
    return await obd2.getNearbyPairedDevices;
  }

  Future<void> connect(BluetoothDevice device) async {
    await obd2.getConnection(
      device,
      (connection) async {
        print('Connected to ${device.address}');
        await _initObd();
      },
      (err) {
        print("Error: $err");
      },
    );
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

    const String paramJson = '''[
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

    final waitMs = await obd2.configObdWithJSON(configJson,);

    await Future.delayed(Duration(milliseconds: waitMs));
    await obd2.getParamsFromJSON(paramJson);
  }

void startListening(Function(String) onData) async {
  onDataReceived = onData;

  final alreadyInit = await obd2.isListenToDataInitialed;

  if (!alreadyInit) {
    await obd2.setOnDataReceived(
      (command, response, requestCode) {
        onDataReceived?.call('$command: $response');
        print("$command => $response");
      },
    );
  }
}

  void stopListening(device) {
    _dataSubscription?.cancel();
    obd2.unpairWithDevice(device);
    _dataSubscription = null;
  }
}
