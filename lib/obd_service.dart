import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:obd_connection_ii/obd_connection_ii.dart';

class ObdService {
  final ObdConnectionII _obd2 = ObdConnectionII();
  StreamSubscription? _dataSubscription;
  Function(String)? onDataReceived;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    return await _obd2.getNearbyPairedDevices;
  }

  Future<void> connect(BluetoothDevice device) async {
    await _obd2.getConnection(device, (connection) {
      print('Connected to ${device.name}');
    }, (message) {
      print('Error connecting: $message');
    });
  }

  void startListening(Function(String) onData) {
    onDataReceived = onData;
    _dataSubscription = _obd2.setOnDataReceived((command, response, requestCode) {
      onDataReceived?.call('$command: $response');
    });

    // Example of sending a command to get RPM
    Timer.periodic(const Duration(seconds: 1), (timer) {
      _obd2.getObdData('{"01":"0C"}');
    });
  }

  void stopListening() {
    _dataSubscription?.cancel();
  }
}
