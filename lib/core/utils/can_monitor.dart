/// The ECU's own fuel signal, read from the broadcast CAN traffic.
///
/// On the Kia Rio 2011 powertrain bus (ISO 15765, 11-bit 500 kbit/s) ID 0x545
/// bytes 1-2 (16-bit little-endian) are `FCO`, the engine ECU's fuel
/// consumption: 0 during overrun fuel cut, ~17-26 at warm idle, past 255
/// (byte 2 = 1) at full load. The opendbc file `hyundai_i30_2014.dbc`
/// (reverse-engineered, not a factory document) defines it as 0.128 uL per
/// count; the later `EMS14` layout moved it to ID 0x200.
///
/// A count is the fuel injected during one message period. 0x545 is sent once
/// per cycle of the 10 ms powertrain messages (one 0x545 per 0x316 in 98.6% of
/// a recording), so 0.128 uL / 10 ms = [mlPerSecPerCount]. The period is
/// measured live from the frames per capture window ([ObdService]
/// `canFramePeriodMs`) and logged with each read to confirm it.
///
/// The raw value and the whole frame are recorded, so any later calibration
/// applies to old trips too.
class CanFuelSignal {
  const CanFuelSignal._();

  /// 11-bit CAN ID, as `AT CRA` takes it.
  static const String canId = '545';

  /// Index of the fuel value's low byte in the 8-byte frame; the high byte
  /// follows it.
  static const int fuelByte = 1;

  /// The raw fuel count of a 0x545 frame: `byte1 + 256 * byte2`, or null when
  /// the frame is too short.
  static int? rawFromFrame(List<int> frame) => frame.length > fuelByte + 1
      ? frame[fuelByte] | (frame[fuelByte + 1] << 8)
      : null;

  /// Mean count over [frames], or null when none decodes. One read prints
  /// ~12 consecutive frames (~120 ms of fuel); their mean is a less noisy
  /// sample of the flow than the newest frame alone.
  static double? meanRaw(Iterable<List<int>> frames) {
    var sum = 0;
    var n = 0;
    for (final frame in frames) {
      final raw = rawFromFrame(frame);
      if (raw == null) continue;
      sum += raw;
      n++;
    }
    return n == 0 ? null : sum / n;
  }

  /// [rawFromFrame] of a frame stored as hex (`8C 12 01 89 ...`), or null.
  static int? rawFromHex(String? hex) {
    if (hex == null) return null;
    final bytes = <int>[];
    for (final part in hex.trim().split(RegExp(r'\s+'))) {
      final b = part.length == 2 ? int.tryParse(part, radix: 16) : null;
      if (b == null) return null;
      bytes.add(b);
    }
    return rawFromFrame(bytes);
  }

  /// Fuel per count, from the DBC.
  static const double microLitresPerCount = 0.128;

  /// Assumed 0x545 message period; see [CanFuelSignal].
  static const double framePeriodMs = 10;

  /// mL/s per raw count: uL per ms is mL per s, so 0.128 / 10 = 0.0128.
  static const double mlPerSecPerCount = microLitresPerCount / framePeriodMs;

  static double mlPerSecFromRaw(num raw) => raw * mlPerSecPerCount;
}

/// One [CanFuelSignal] read: the newest frame, the mean count over all the
/// frames the adapter printed, how many there were and how long it listened
/// for them.
class CanRead {
  const CanRead(this.frame, {this.rawMean, this.frameCount, this.listenMs});

  final List<int> frame;
  final double? rawMean;
  final int? frameCount;
  final int? listenMs;
}

/// Splits the reply to `AT MA` into 8-byte CAN frames.
///
/// The Bluetooth plugin strips CR/LF, so with `AT S0`, `AT H0` and a receive
/// filter on one ID the frames arrive glued together as one hex string:
/// `8CA600898C038C038CA60089...STOPPED`. Every frame of that ID is 8 bytes,
/// so the string is cut into 16-character pieces. Only the last line can be
/// cut short (by the character that stops the monitor); it is the leftover and
/// is dropped. Non-hex text (`STOPPED`, `BUFFER FULL`, `<RX ERROR`) separates
/// runs that are cut independently, since a run ends at a line boundary.
List<List<int>> parseMonitorFrames(String payload, {int frameBytes = 8}) {
  var text = payload;
  final colon = text.indexOf(':');
  if (colon >= 0 && colon < 2) text = text.substring(colon + 1);
  text = text.toUpperCase().replaceAll(' ', '');
  // Messages whose letters are partly hex must not stick to a neighbouring frame.
  text = text.replaceAll(_elmMessages, '|');
  final frames = <List<int>>[];
  final width = frameBytes * 2;
  for (final run in text.split(RegExp('[^0-9A-F]+'))) {
    for (var start = 0; start + width <= run.length; start += width) {
      final chunk = run.substring(start, start + width);
      frames.add([
        for (var i = 0; i < width; i += 2)
          int.parse(chunk.substring(i, i + 2), radix: 16),
      ]);
    }
  }
  return frames;
}

/// Frames from a monitor reply printed with headers on and spaces off
/// (`AT H1`, `AT S0`) while the receive filter is set to [canId]: every line
/// is the 3-digit ID plus 16 hex digits.
///
/// Returns null when a line belongs to another ID, i.e. the adapter does not
/// apply its receive filter while monitoring (some clones). The lines are then
/// not fixed-length and only [parseTaggedFrames] can split them.
List<List<int>>? parseHeaderedFrames(String payload, String canId) {
  final frames = <List<int>>[];
  const width = 3 + 16;
  for (final run in _hexRuns(payload)) {
    for (var start = 0; start + width <= run.length; start += width) {
      final chunk = run.substring(start, start + width);
      if (!chunk.startsWith(canId)) return null;
      frames.add(_bytes(chunk.substring(3)));
    }
    // A cut-off last line is fine; a leftover that is not the start of one
    // of our lines means the lines were not all ours.
    final rest = run.length % width;
    if (rest >= 3 && !run.substring(run.length - rest).startsWith(canId)) {
      return null;
    }
  }
  return frames;
}

/// Frames of [canId] from a monitor reply printed with headers and spaces on
/// (`AT H1`, `AT S1`), for adapters that pass other IDs too. With CR stripped,
/// a line's last byte and the next line's ID meet in one 5-character token
/// (`03545`); everything else is a 3-character ID or a 2-character byte.
List<List<int>> parseTaggedFrames(String payload, String canId) {
  final frames = <List<int>>[];
  String? id;
  var data = <int>[];
  void flush() {
    if (id == canId && data.length == 8) frames.add(data);
    id = null;
    data = <int>[];
  }

  var text = payload;
  final colon = text.indexOf(':');
  if (colon >= 0 && colon < 2) text = text.substring(colon + 1);
  text = text.toUpperCase().replaceAll(_spacedElmMessages, ' | ');
  for (final token in text.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(token)) {
      flush();
      continue;
    }
    switch (token.length) {
      case 2:
        if (id != null) data.add(int.parse(token, radix: 16));
      case 3:
        flush();
        id = token;
      case 5:
        if (id != null) data.add(int.parse(token.substring(0, 2), radix: 16));
        flush();
        id = token.substring(2);
      default:
        flush();
    }
  }
  flush();
  return frames;
}

Iterable<String> _hexRuns(String payload) {
  var text = payload;
  final colon = text.indexOf(':');
  if (colon >= 0 && colon < 2) text = text.substring(colon + 1);
  text = text.toUpperCase().replaceAll(' ', '').replaceAll(_elmMessages, '|');
  return text.split(RegExp('[^0-9A-F]+'));
}

List<int> _bytes(String hex) => [
      for (var i = 0; i + 2 <= hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];

final RegExp _spacedElmMessages = RegExp(
  r'STOPPED|BUFFER FULL|CAN ERROR|BUS ERROR|BUS BUSY|<?DATA ERROR|<?RX ERROR'
  r'|FB ERROR|NO DATA|ELM327 V?[0-9.]*|SEARCHING\.*|OK|\?',
);

final RegExp _elmMessages = RegExp(
  r'STOPPED|BUFFERFULL|CANERROR|BUSERROR|BUSBUSY|DATAERROR|<RXERROR|RXERROR'
  r'|FBERROR|NODATA|ELM327V?[0-9.]*|SEARCHING\.*|OK|\?',
);

/// Hex form of a frame as the trip CSV stores it, e.g. `8C A6 00 89 8C 03 8C 03`.
String canFrameHex(List<int> frame) => frame
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');
