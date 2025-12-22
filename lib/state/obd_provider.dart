import 'dart:convert';

import 'package:flutter/foundation.dart';
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
    _log('RAW $data');
    final splitIndex = data.indexOf(':');
    if (splitIndex == -1) {
      _handleRawPayload(data.trim());
      notifyListeners();
      return;
    }
    final pid = data.substring(0, splitIndex).trim();
    final payload = data.substring(splitIndex + 1).trim();

    lastRawMessage = data;
    lastUpdate = DateTime.now();

    if (pid.isEmpty || pid.toUpperCase() == 'RAW') {
      _handleRawPayload(payload);
      notifyListeners();
      return;
    }

    if (pid.toUpperCase() == 'PARAMETER') {
      _handleBatchPayload(payload);
      _log('PARSED batch rpm=$rpm map=$mapKpa iatK=$iatKelvin');
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
        _log('PARSED rpm=$rpm');
        break;
      case '01 0B':
        if (numeric != null) {
          mapKpa = numeric;
        } else if (bytes.length > dataStart) {
          mapKpa = bytes[dataStart].toDouble();
        }
        _log('PARSED map=$mapKpa');
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
        _log('PARSED iatK=$iatKelvin');
        break;
    }
    notifyListeners();
  }

  void _handleRawPayload(String payload) {
    if (payload.isEmpty) return;
    final bytes = _parseHexBytes(payload);
    if (bytes.length >= 2 && bytes[0] == 0x41) {
      final pidByte = bytes[1];
      switch (pidByte) {
        case 0x0C:
          if (bytes.length >= 4) {
            rpm = ((bytes[2] * 256) + bytes[3]) / 4;
            _log('RAW rpm=$rpm');
          }
          break;
        case 0x0B:
          if (bytes.length >= 3) {
            mapKpa = bytes[2].toDouble();
            _log('RAW map=$mapKpa');
          }
          break;
        case 0x0F:
          if (bytes.length >= 3) {
            iatKelvin = (bytes[2] - 40) + 273.15;
            _log('RAW iatK=$iatKelvin');
          }
          break;
      }
    } else {
      final numeric = _parseFirstNumber(payload);
      if (numeric != null) {
        _log('RAW numeric=$numeric');
      }
    }
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
    _log('PID $pid response=$response => rpm=$rpm map=$mapKpa iatK=$iatKelvin');
  }

  List<int> _parseHexBytes(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final bytes = <int>[];
    if (cleaned.length >= 2) {
      for (var i = 0; i + 1 < cleaned.length; i += 2) {
        final pair = cleaned.substring(i, i + 2);
        final value = int.tryParse(pair, radix: 16);
        if (value != null) bytes.add(value);
      }
      if (bytes.isNotEmpty) return bytes;
    }

    final tokens = raw.trim().split(RegExp(r'\s+'));
    for (final token in tokens) {
      final tokenCleaned = token.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
      if (tokenCleaned.isEmpty) continue;
      final value = int.tryParse(tokenCleaned, radix: 16);
      if (value != null) bytes.add(value);
    }
    return bytes;
  }

  double? _parseFirstNumber(String raw) {
    final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(raw);
    if (match == null) return null;
    return double.tryParse(match.group(0) ?? '');
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String();
    debugPrint('[OBD_PROVIDER][$timestamp] $message');
  }
}
