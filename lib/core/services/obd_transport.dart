import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

/// How the phone reaches the ELM327 adapter.
enum ObdConnectionType { bluetooth, wifi }

/// An ELM327 adapter the user picked: a paired Bluetooth device, or a Wi-Fi
/// adapter reached over TCP.
class ObdDevice {
  ObdDevice.bluetooth(BluetoothDevice device)
    : type = ObdConnectionType.bluetooth,
      name = device.name ?? 'Bluetooth OBD',
      address = device.address,
      port = null,
      _bluetooth = device;

  ObdDevice.wifi({required String host, required int this.port})
    : type = ObdConnectionType.wifi,
      name = 'Wi-Fi OBD ($host:$port)',
      address = host,
      _bluetooth = null;

  /// Factory defaults of almost every Wi-Fi ELM327 clone.
  static const String defaultWifiHost = '192.168.0.10';
  static const int defaultWifiPort = 35000;

  final ObdConnectionType type;
  final String name;

  /// MAC address for Bluetooth, host name or IP for Wi-Fi.
  final String address;
  final int? port;
  final BluetoothDevice? _bluetooth;

  /// Stable per-adapter key, e.g. for the negotiated-protocol cache. The
  /// Bluetooth form is the bare MAC so caches written before Wi-Fi support
  /// stay valid.
  String get id =>
      type == ObdConnectionType.wifi ? 'wifi_$address:$port' : address;

  ObdTransport createTransport() => type == ObdConnectionType.wifi
      ? WifiObdTransport(address, port!)
      : BluetoothObdTransport(_bluetooth!);
}

/// A byte pipe to an ELM327 that delivers one payload per `>` prompt.
///
/// Every payload is `': <response>'` with CR, LF, the prompt and
/// `SEARCHING...` removed — the exact shape the Bluetooth plugin has always
/// produced, so the decoder and the service never see which link is in use.
abstract class ObdTransport {
  bool get isConnected;

  Future<void> open({required void Function(String payload) onPayload});

  Future<void> write(String command);

  Future<void> close();

  /// True when a failed [open] is worth retrying (adapter briefly busy or
  /// still booting), false when it cannot succeed without user action.
  bool isRetryableOpenError(Object err);
}

/// Bluetooth SPP link through the obd2_plugin / flutter_bluetooth_serial
/// stack.
class BluetoothObdTransport implements ObdTransport {
  BluetoothObdTransport(this._device);

  final BluetoothDevice _device;

  // A fresh plugin per transport is mandatory: the plugin refuses a second
  // setOnDataReceived and getConnection would reuse a stale connection.
  final Obd2Plugin _obd2 = Obd2Plugin();

  @override
  bool get isConnected => _obd2.connection?.isConnected ?? false;

  @override
  Future<void> open({required void Function(String payload) onPayload}) async {
    await FlutterBluetoothSerial.instance.requestEnable();
    await _obd2.getConnection(_device, (_) {}, (_) {});
    if (_obd2.connection == null) {
      throw StateError('Bluetooth connection was not established');
    }
    // The plugin attaches its input listener to `connection`, so this must
    // run after the socket exists or the transport stays deaf.
    await _obd2.setOnDataReceived((command, response, requestCode) {
      onPayload('$command: $response');
    });
  }

  @override
  Future<void> write(String command) async {
    final conn = _obd2.connection;
    if (conn == null || !conn.isConnected) {
      throw StateError('OBD Bluetooth connection lost');
    }
    // ELM327 terminates on CR; a trailing LF is echoed back as noise.
    conn.output.add(Uint8List.fromList(utf8.encode('$command\r')));
    await conn.output.allSent;
  }

  @override
  Future<void> close() async {
    await _obd2.disconnect();
  }

  @override
  bool isRetryableOpenError(Object err) =>
      err is PlatformException && err.code == 'connect_error';
}

/// TCP link to a Wi-Fi ELM327 (the phone joins the adapter's own network).
class WifiObdTransport implements ObdTransport {
  WifiObdTransport(this._host, this._port);

  final String _host;
  final int _port;

  static const Duration _connectTimeout = Duration(seconds: 5);

  Socket? _socket;
  bool _open = false;
  final StringBuffer _pending = StringBuffer();

  @override
  bool get isConnected => _open;

  @override
  Future<void> open({required void Function(String payload) onPayload}) async {
    final socket = await Socket.connect(_host, _port, timeout: _connectTimeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _open = true;
    socket.listen(
      (data) => _onBytes(data, onPayload),
      onError: (Object _) => _open = false,
      onDone: () => _open = false,
      cancelOnError: true,
    );
  }

  /// Buffers bytes until the ELM327 `>` prompt. Unlike the Bluetooth plugin,
  /// bytes after a prompt in the same TCP segment are kept for the next
  /// response instead of being merged into this one.
  void _onBytes(List<int> data, void Function(String payload) onPayload) {
    _pending.write(String.fromCharCodes(data));
    var text = _pending.toString();
    var prompt = text.indexOf('>');
    if (prompt < 0) return;
    while (prompt >= 0) {
      onPayload(': ${_clean(text.substring(0, prompt))}');
      text = text.substring(prompt + 1);
      prompt = text.indexOf('>');
    }
    _pending
      ..clear()
      ..write(text);
  }

  static String _clean(String raw) => raw
      .replaceAll('\r', '')
      .replaceAll('\n', '')
      .replaceAll('\x00', '')
      .replaceAll('SEARCHING...', '');

  @override
  Future<void> write(String command) async {
    final socket = _socket;
    if (socket == null || !_open) {
      throw StateError('OBD Wi-Fi connection lost');
    }
    socket.add(utf8.encode('$command\r'));
    await socket.flush();
  }

  @override
  Future<void> close() async {
    _open = false;
    final socket = _socket;
    _socket = null;
    _pending.clear();
    socket?.destroy();
  }

  @override
  bool isRetryableOpenError(Object err) => err is SocketException;
}
