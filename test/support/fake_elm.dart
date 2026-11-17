import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A scripted ELM327 on a TCP socket, so tests drive the real [ObdService] and
/// [WifiObdTransport] end to end.
///
/// Answers the init script, mode-01 requests (single and ISO-TP multi-frame
/// replies, optional response-count digit) and the CAN capture sequence:
/// `AT CAF0/1`, `AT CRA`, `AT AR`, and `AT MA`, which streams 0x545 frames
/// every [frameInterval] until any byte arrives.
///
/// While a receive filter is set, mode-01 requests get `NO DATA`, exactly as a
/// real adapter whose filter hides the ECU's replies. [pidRequestsWhileFiltered]
/// counts them so a test can prove the capture never leaks into polling.
class FakeElm {
  FakeElm._(this._server);

  static Future<FakeElm> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final elm = FakeElm._(server);
    server.listen(elm._onClient);
    return elm;
  }

  final ServerSocket _server;
  Socket? _socket;

  int get port => _server.port;

  /// Settings, as the poll loop must find them after every capture.
  bool caf = true;
  String? cra;
  bool headers = false;
  bool spaces = true;

  /// Set false to emulate a car that does not broadcast 0x545.
  bool sends545 = true;

  /// Set true to emulate an adapter without monitor mode.
  bool rejectsMonitor = false;

  /// Set true to emulate a clone that ignores `AT CRA` while monitoring and
  /// prints the busy 0x316 (7 bytes here, so lines differ in length) as well.
  bool leaksOtherIds = false;

  Duration frameInterval = const Duration(milliseconds: 100);

  int pidRequestsWhileFiltered = 0;
  int monitorSessions = 0;
  final List<String> commands = [];

  /// Fuel byte of the next 0x545 frame; counts up so tests can check order.
  int fuelRaw = 20;

  Timer? _monitorTimer;
  final StringBuffer _line = StringBuffer();

  Future<void> close() async {
    _monitorTimer?.cancel();
    _socket?.destroy();
    await _server.close();
  }

  void _onClient(Socket socket) {
    _socket = socket;
    socket.listen((data) {
      for (final ch in latin1.decode(data).split('')) {
        if (_monitorTimer != null) {
          // Any byte stops the monitor; it is discarded.
          _monitorTimer!.cancel();
          _monitorTimer = null;
          _write('STOPPED\r\r>');
          continue;
        }
        if (ch == '\r') {
          final cmd = _line.toString();
          _line.clear();
          _handle(cmd);
        } else if (ch != '\n') {
          _line.write(ch);
        }
      }
    });
  }

  void _write(String s) => _socket?.add(latin1.encode(s));

  void _reply(String s) => _write('$s\r\r>');

  String _hex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(spaces ? ' ' : '');

  void _handle(String raw) {
    final cmd = raw.replaceAll(' ', '').toUpperCase();
    commands.add(raw);
    if (cmd.isEmpty) return _reply('?');
    if (cmd.startsWith('AT')) return _handleAt(cmd.substring(2));
    if (cmd.startsWith('01')) return _handleMode01(cmd.substring(2));
    _reply('?');
  }

  void _handleAt(String a) {
    if (a == 'Z' || a == 'WS') {
      caf = true;
      cra = null;
      headers = false;
      spaces = true;
      return _reply('ELM327 v2.1');
    }
    if (RegExp(r'^[ELSH][01]$').hasMatch(a)) {
      if (a[0] == 'S') spaces = a[1] == '1';
      if (a[0] == 'H') headers = a[1] == '1';
      return _reply('OK');
    }
    if (a.startsWith('SP') || a.startsWith('AT') || a.startsWith('ST')) {
      return _reply('OK');
    }
    if (a == 'DPN') return _reply('A6');
    if (a == 'CAF0' || a == 'CAF1') {
      caf = a == 'CAF1';
      return _reply('OK');
    }
    if (a == 'AR' || a == 'CRA') {
      cra = null;
      return _reply('OK');
    }
    if (RegExp(r'^CRA[0-9A-F]{3}$').hasMatch(a)) {
      cra = a.substring(3);
      return _reply('OK');
    }
    if (a == 'MA') {
      if (rejectsMonitor) return _reply('?');
      monitorSessions += 1;
      String line(String id, List<int> data) {
        // With formatting on, 0x8C is no valid ISO-TP PCI byte.
        if (caf) return '<DATA ERROR\r';
        final head = headers ? '$id${spaces ? ' ' : ''}' : '';
        return '$head${_hex(data)}\r';
      }

      _monitorTimer = Timer.periodic(frameInterval, (_) {
        if (leaksOtherIds) {
          _write(line('316', [0x01, 0x2D, 0x24, 0x0B, 0x2C, 0x1E, 0x00]));
        }
        if (!sends545 || (cra != null && cra != '545' && !leaksOtherIds)) {
          return;
        }
        final frame = [0x8C, fuelRaw & 0xFF, 0x00, 0x89, 0x2B, 0x03, 0x2B, 0x03];
        fuelRaw += 1;
        _write(line('545', frame));
        if (leaksOtherIds) {
          _write(line('316', [0x01, 0x2E, 0x29, 0x0B, 0x2C, 0x1E, 0x00]));
        }
      });
      return;
    }
    _reply('?');
  }

  // Supports 03 05 06 07 0B 0C 0D 0F 11 (+ next range), 2F 33 (+ next range), 42.
  static const Map<int, List<int>> _bitmasks = {
    0x00: [0x2E, 0x3A, 0x80, 0x01],
    0x20: [0x00, 0x02, 0x20, 0x01],
    0x40: [0x40, 0x00, 0x00, 0x00],
  };

  static const Map<int, List<int>> _values = {
    0x03: [0x02, 0x00],
    0x05: [0x7B],
    0x06: [0x80],
    0x07: [0x7C],
    0x0B: [0x23],
    0x0C: [0x0B, 0x40],
    0x0D: [0x00],
    0x0F: [0x46],
    0x11: [0x24],
    0x2F: [0x80],
    0x33: [0x64],
    0x42: [0x36, 0xB0],
  };

  void _handleMode01(String body) {
    // A trailing single digit is the response count.
    var pids = body;
    if (pids.length.isOdd) pids = pids.substring(0, pids.length - 1);
    if (cra != null) {
      pidRequestsWhileFiltered += 1;
      return _reply('NO DATA');
    }
    final out = <int>[0x41];
    for (var i = 0; i + 2 <= pids.length; i += 2) {
      final pid = int.parse(pids.substring(i, i + 2), radix: 16);
      final data = _bitmasks[pid] ?? _values[pid];
      if (data == null) continue;
      out
        ..add(pid)
        ..addAll(data);
    }
    if (out.length == 1) return _reply('NO DATA');
    if (out.length <= 7) return _reply(_hex(out));
    // ISO-TP: byte count, then 6 bytes in frame 0 and 7 in each next one.
    final lines = [out.length.toRadixString(16).padLeft(3, '0').toUpperCase()];
    var index = 0;
    var frame = 0;
    while (index < out.length) {
      final take = frame == 0 ? 6 : 7;
      final end = index + take < out.length ? index + take : out.length;
      lines.add('${frame.toRadixString(16).toUpperCase()}:${spaces ? ' ' : ''}'
          '${_hex(out.sublist(index, end))}');
      index = end;
      frame = (frame + 1) % 16;
    }
    _reply(lines.join('\r'));
  }
}
