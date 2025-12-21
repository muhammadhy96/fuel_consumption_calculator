import 'dart:convert';

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
    if (!_connected) return 0;
    final iat = iatKelvin > 0 ? iatKelvin : 293.15;
    return _obdService.fuelFlow(rpm, mapKpa, iat);
  }

  void _handleObdData(String data) {
    final parts = data.split(':');
    if (parts.length != 2) return;
    final pid = parts[0].trim();
    final payload = parts[1].trim();

    lastRawMessage = data;
    lastUpdate = DateTime.now();

    if (pid.toUpperCase() == 'PARAMETER') {
      _handleBatchPayload(payload);
      notifyListeners();
      return;
    }

    final numeric = _parseFirstNumber(payload);
    final bytes = numeric == null ? _parseHexBytes(payload) : const <int>[];
    int dataStart = 0;
    if (bytes.length >= 2 && bytes[0] == 0x41) {
      dataStart = 2;
    }

    switch (pid) {
      case '01 0C':
        if (numeric != null) {
          rpm = numeric;
        } else if (bytes.length >= dataStart + 2) {
          rpm = ((bytes[dataStart] * 256) + bytes[dataStart + 1]) / 4;
        }
        break;
      case '01 0B':
        if (numeric != null) {
          mapKpa = numeric;
        } else if (bytes.length > dataStart) {
          mapKpa = bytes[dataStart].toDouble();
        }
        break;
      case '01 0F':
        double? celsius;
        if (numeric != null) {
          celsius = numeric;
        } else if (bytes.length > dataStart) {
          celsius = bytes[dataStart] - 40;
        }
        if (celsius != null) {
          iatKelvin = celsius + 273.15;
        }
        break;
    }
    notifyListeners();
  }

  void _handleBatchPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map) continue;
        final pid = (item['PID'] as String?)?.trim();
        final response = (item['response'] as String?)?.trim();
        if (pid == null || response == null || response.isEmpty) continue;
        _updatePidValue(pid, response);
      }
    } catch (_) {
      // Ignore malformed payloads.
    }
  }

  void _updatePidValue(String pid, String response) {
    final numeric = _parseFirstNumber(response);
    if (numeric == null) return;
    switch (pid) {
      case '01 0C':
        rpm = numeric;
        break;
      case '01 0B':
        mapKpa = numeric;
        break;
      case '01 0F':
        iatKelvin = numeric + 273.15;
        break;
    }
  }

  List<int> _parseHexBytes(String raw) {
    final tokens = raw.trim().split(RegExp(r'\\s+'));
    final bytes = <int>[];
    for (final token in tokens) {
      final cleaned = token.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
      if (cleaned.isEmpty) continue;
      final value = int.tryParse(cleaned, radix: 16);
      if (value != null) bytes.add(value);
    }
    return bytes;
  }

  double? _parseFirstNumber(String raw) {
    final match = RegExp(r'-?\\d+(?:\\.\\d+)?').firstMatch(raw);
    if (match == null) return null;
    return double.tryParse(match.group(0) ?? '');
  }
}
