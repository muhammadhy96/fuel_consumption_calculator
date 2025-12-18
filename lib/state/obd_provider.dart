import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import '../core/services/obd_service.dart';

class ObdProvider extends ChangeNotifier {
  ObdProvider(this._obdService);

  final ObdService _obdService;

  BluetoothDevice? _connectedDevice;
  bool _connected = false;
  bool _live = false;

  double rpm = 0;
  double mapKpa = 0;
  double iatKelvin = 0;
  String? lastRawMessage;
  DateTime? lastUpdate;

  BluetoothDevice? get device => _connectedDevice;
  bool get connected => _connected;
  bool get live => _live;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    return _obdService.getPairedDevices();
  }

  Future<void> connect(BluetoothDevice device) async {
    await _obdService.connect(device);
    _connectedDevice = device;
    _connected = true;
    notifyListeners();
  }

  Future<String?> verifyConnection() async {
    if (!_connected) return null;
    final sample = await _obdService.requestSingleFrame();
    if (sample != null) {
      lastRawMessage = sample;
      lastUpdate = DateTime.now();
      notifyListeners();
    }
    return sample;
  }

  Future<void> startLive() async {
    if (!_connected || _live) return;
    await _obdService.startListening(_handleObdData);
    _live = true;
    notifyListeners();
  }

  void stopLive() {
    if (_connectedDevice != null) {
      _obdService.stopListening(_connectedDevice!);
    }
    _live = false;
    rpm = 0;
    mapKpa = 0;
    iatKelvin = 0;
    notifyListeners();
  }

  void disconnect() {
    stopLive();
    _connectedDevice = null;
    _connected = false;
    lastRawMessage = null;
    lastUpdate = null;
    notifyListeners();
  }

  double calculateFuelFlow() {
    if (!_connected || iatKelvin <= 0) return 0;
    return _obdService.fuelFlow(rpm, mapKpa, iatKelvin);
  }

  void _handleObdData(String data) {
    final parts = data.split(':');
    if (parts.length != 2) return;
    final pid = parts[0].trim();
    final value = double.tryParse(parts[1].trim());
    if (value == null) return;

    lastRawMessage = data;
    lastUpdate = DateTime.now();

    switch (pid) {
      case '01 0C':
        rpm = value;
        break;
      case '01 0B':
        mapKpa = value;
        break;
      case '01 0F':
        iatKelvin = value + 273.15;
        break;
    }
    notifyListeners();
  }
}
