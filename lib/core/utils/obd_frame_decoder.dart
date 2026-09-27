import '../constants/obd_pids.dart';

/// One decoded telemetry field.
class ObdDecodeResult {
  const ObdDecodeResult({
    required this.values,
    required this.supportBitmasks,
  });

  /// Canonical PID key -> decoded engineering value, in the units listed below.
  ///   '010C' rpm            '010D' km/h        '010B' kPa
  ///   '0110' g/s            '0104' percent     '010F' Kelvin
  ///   '0105' Kelvin         '0111' percent     '0142' volts
  ///   '012F' percent        '0133' kPa         '0144' ratio (lambda)
  ///   '0106' percent        '0107' percent     (fuel trims, -100..+99.2)
  ///   '015E' mL/s           (already converted from L/h)
  final Map<String, double> values;

  /// rangeStart byte (0x00 / 0x20 / 0x40) -> the 4 bitmask bytes.
  final Map<int, List<int>> supportBitmasks;

  bool get isEmpty => values.isEmpty && supportBitmasks.isEmpty;

  /// Shared instance for payloads that yielded nothing at all, so the hot path
  /// allocates no maps when a response is empty or unparseable.
  static const ObdDecodeResult _empty = ObdDecodeResult(
    values: <String, double>{},
    supportBitmasks: <int, List<int>>{},
  );
}

/// Pure, hardware-free decoder for ELM327 mode-01 / mode-22 responses.
///
/// Mode 01 responses begin with 0x41. There can be multiple 0x41 blocks in a
/// multi-frame reply; each block is followed by repeating `pid + N` groups
/// until the next 0x41 or the end of the payload. Decoding is decoupled from
/// the command that was sent — so if the ECU echoes PIDs out of order, or packs
/// six PIDs into one bulk reply, we still decode.
///
/// The decoder never throws: a truncated or unrecognised group aborts only the
/// 0x41 block it appears in, and scanning resumes at the next block.
class ObdFrameDecoder {
  const ObdFrameDecoder();

  /// Canonical PID key for each mode-01 PID byte, or null when unknown.
  /// Built once so the hot path never allocates a key string per PID.
  static final List<String?> _pidKeyByByte = _buildPidKeyTable();

  /// Data-byte count for each mode-01 PID byte. Only meaningful where
  /// [_pidKeyByByte] is non-null.
  static final List<int> _pidLengthByByte = _buildPidLengthTable();

  /// Strips the `command: ` prefix if present, hex-decodes, and decodes every
  /// `41 PID DATA...` group, `62 PIDHI PIDLO DATA...` (mode 22) group, and
  /// supported-PID bitmask in the payload.
  ObdDecodeResult decode(String raw) {
    final colonIndex = raw.indexOf(':');
    final start = colonIndex >= 0 ? colonIndex + 1 : 0;
    // A second colon means the ELM327 printed a multi-line (ISO-TP) reply, so
    // the payload carries line markers that must come out before the hex is
    // paired up. Single-frame replies take the cheaper straight scan.
    final bytes = raw.indexOf(':', start) >= 0
        ? _parseFramedHexBytes(raw, start)
        : _parseHexBytesFrom(raw, start);
    if (bytes.isEmpty) return ObdDecodeResult._empty;

    // Allocated lazily so a garbage frame costs nothing.
    Map<String, double>? values;
    Map<int, List<int>>? bitmasks;

    final end = bytes.length;
    var i = 0;
    while (i < end) {
      final modeByte = bytes[i];

      if (modeByte == 0x41) {
        i += 1;
        // Supported-PID bitmask responses (01 00, 01 20, 01 40) carry exactly
        // 4 data bytes and must not be decoded as telemetry PIDs.
        if (i < end &&
            (bytes[i] == 0x00 || bytes[i] == 0x20 || bytes[i] == 0x40) &&
            i + 5 <= end) {
          bitmasks ??= <int, List<int>>{};
          bitmasks[bytes[i]] = <int>[
            bytes[i + 1],
            bytes[i + 2],
            bytes[i + 3],
            bytes[i + 4],
          ];
          i += 5;
          continue;
        }
        // Walk the inner run until we exhaust the stream or bump into another
        // 0x41 header, which marks the next block.
        while (i < end && bytes[i] != 0x41) {
          final pidByte = bytes[i];
          final pidKey = _pidKeyByByte[pidByte];
          if (pidKey == null) {
            // Unknown PID byte — the rest of this block is unaligned garbage.
            i = _endOfBlock(bytes, i);
            break;
          }
          final dataLength = _pidLengthByByte[pidByte];
          if (i + 1 + dataLength > end) {
            // Truncated final group — abort this block, never read past the end.
            i = _endOfBlock(bytes, i);
            break;
          }
          values ??= <String, double>{};
          _decodePid(values, pidKey, bytes, i + 1, dataLength);
          i += 1 + dataLength;
        }
        continue;
      }

      if (modeByte == 0x62 && i + 2 < end) {
        // Mode 22 response: 62 PIDHI PIDLO DATA...
        // Only extended MAF (22 01 01) is handled today; it maps onto '0110'.
        if (bytes[i + 1] == 0x01 && bytes[i + 2] == 0x01 && i + 4 < end) {
          values ??= <String, double>{};
          values['0110'] = ((bytes[i + 3] * 256) + bytes[i + 4]) / 100;
          i += 5;
          continue;
        }
        i += 3;
        continue;
      }

      // Unknown byte — advance and keep scanning. This keeps us robust against
      // CAN header garbage or stray bytes the plugin may leave in.
      i += 1;
    }

    if (values == null && bitmasks == null) return ObdDecodeResult._empty;
    return ObdDecodeResult(
      values: values ?? const <String, double>{},
      supportBitmasks: bitmasks ?? const <int, List<int>>{},
    );
  }

  /// Hex-decodes a payload to bytes. Non-hex characters are stripped.
  /// Exposed for tests.
  static List<int> parseHexBytes(String raw) => _parseHexBytesFrom(raw, 0);

  /// Index of the next 0x41 block header at or after [start], or the end of
  /// [bytes] when there is none. [start] never points at a 0x41 itself, so the
  /// result always advances and scanning cannot stall.
  static int _endOfBlock(List<int> bytes, int start) {
    var i = start;
    final end = bytes.length;
    while (i < end && bytes[i] != 0x41) {
      i += 1;
    }
    return i;
  }

  /// Reads [dataLength] data bytes starting at [start] straight out of [bytes]
  /// — no per-PID sublist allocation — and writes the engineering value.
  static void _decodePid(
    Map<String, double> values,
    String pidKey,
    List<int> bytes,
    int start,
    int dataLength,
  ) {
    switch (pidKey) {
      case '010C':
        if (dataLength >= 2) {
          values[pidKey] = ((bytes[start] * 256) + bytes[start + 1]) / 4;
        }
        break;
      case '010D':
      case '010B':
      case '0133':
        values[pidKey] = bytes[start].toDouble();
        break;
      case '0110':
        if (dataLength >= 2) {
          values[pidKey] = ((bytes[start] * 256) + bytes[start + 1]) / 100;
        }
        break;
      case '0104':
      case '0111':
      case '012F':
        values[pidKey] = (bytes[start] * 100) / 255;
        break;
      case '0106':
      case '0107':
        values[pidKey] = (bytes[start] * 100) / 128 - 100;
        break;
      case '010F':
      case '0105':
        values[pidKey] = (bytes[start] - 40) + 273.15;
        break;
      case '0142':
        if (dataLength >= 2) {
          values[pidKey] = ((bytes[start] * 256) + bytes[start + 1]) / 1000;
        }
        break;
      case '0144':
        if (dataLength >= 2) {
          values[pidKey] = ((bytes[start] * 256) + bytes[start + 1]) / 32768;
        }
        break;
      case '015E':
        if (dataLength >= 2) {
          final lph = ((bytes[start] * 256) + bytes[start + 1]) / 20;
          values[pidKey] = (lph * 1000) / 3600;
        }
        break;
    }
  }

  /// Single-pass hex scan starting at [start]. Equivalent to stripping every
  /// non-hex character and pairing the rest, but without building the
  /// intermediate string or a substring per byte. A trailing odd nibble is
  /// discarded.
  static List<int> _parseHexBytesFrom(String raw, int start) {
    final bytes = <int>[];
    _appendHexBytes(bytes, raw, start, raw.length);
    return bytes;
  }

  /// Hex scan for an ELM327 multi-line (ISO-TP) reply.
  ///
  /// A mode-01 reply longer than 7 data bytes — which every 6-PID bulk request
  /// produces — does not fit in one CAN frame, so the adapter prints a 3-digit
  /// total-length line followed by one line per frame, each tagged with its
  /// ISO-TP sequence number and a colon:
  ///
  ///     00F
  ///     0:410C1AF80D3C
  ///     1:0B62101A2C0480
  ///     2:0F32AAAAAAAAAA
  ///
  /// The transport strips CR and LF without putting anything in their place, so
  /// those markers arrive glued to the data. Scanning them as hex shifts every
  /// byte after the first frame by one nibble and turns the whole reply into
  /// garbage, so they are removed here: the length line is dropped, and the
  /// single hex digit immediately before each colon is the *next* frame's
  /// sequence tag rather than data.
  static List<int> _parseFramedHexBytes(String raw, int start) {
    final bytes = <int>[];
    final length = raw.length;
    var segmentStart = start;
    var isFirstSegment = true;
    while (true) {
      final colon = raw.indexOf(':', segmentStart);
      final segmentEnd = colon < 0 ? length : colon;
      var dataEnd = segmentEnd;
      // Drop the sequence tag of the frame that starts after this colon. It is
      // always the single character directly in front of the colon, so nothing
      // is trimmed when the adapter emitted a colon for another reason.
      final tag = segmentEnd - 1;
      if (colon >= 0 &&
          tag >= segmentStart &&
          _hexNibble(raw.codeUnitAt(tag)) >= 0) {
        dataEnd = tag;
      }
      // The leading segment is the total-length line (3 hex digits) whenever
      // it is too short to be a frame's worth of data. Anything longer is real
      // data — a payload that arrived without the `command: ` prefix starts
      // mid-frame — and is kept.
      final isLengthHeader =
          isFirstSegment && _hexDigitCount(raw, segmentStart, dataEnd) <= 3;
      if (!isLengthHeader) {
        _appendHexBytes(bytes, raw, segmentStart, dataEnd);
      }
      if (colon < 0) return bytes;
      segmentStart = colon + 1;
      isFirstSegment = false;
    }
  }

  /// Pairs the hex digits in `raw[start, end)` into [bytes], ignoring every
  /// other character. Alignment restarts on each call, so a corrupt line cannot
  /// shift the frames that follow it, and a trailing odd nibble is discarded.
  static void _appendHexBytes(
    List<int> bytes,
    String raw,
    int start,
    int end,
  ) {
    var high = -1;
    for (var i = start; i < end; i++) {
      final nibble = _hexNibble(raw.codeUnitAt(i));
      if (nibble < 0) continue;
      if (high < 0) {
        high = nibble;
      } else {
        bytes.add((high << 4) | nibble);
        high = -1;
      }
    }
  }

  /// Number of hex digits in `raw[start, end)`.
  static int _hexDigitCount(String raw, int start, int end) {
    var count = 0;
    for (var i = start; i < end; i++) {
      if (_hexNibble(raw.codeUnitAt(i)) >= 0) count += 1;
    }
    return count;
  }

  /// Value of a hex digit code unit, or -1 when it is not a hex digit.
  static int _hexNibble(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30; // 0-9
    if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x37; // A-F
    if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x57; // a-f
    return -1;
  }

  static List<String?> _buildPidKeyTable() {
    final table = List<String?>.filled(256, null);
    for (final key in pidByteLength.keys) {
      final pidByte = _pidByteOf(key);
      if (pidByte < 0) continue;
      table[pidByte] = key.toUpperCase();
    }
    return table;
  }

  static List<int> _buildPidLengthTable() {
    final table = List<int>.filled(256, 0);
    for (final entry in pidByteLength.entries) {
      final pidByte = _pidByteOf(entry.key);
      if (pidByte < 0) continue;
      table[pidByte] = entry.value;
    }
    return table;
  }

  /// PID byte of a canonical mode-01 key such as '010C', or -1 when the key is
  /// not a four-character mode-01 key.
  static int _pidByteOf(String key) {
    final upper = key.toUpperCase();
    if (upper.length != 4 || !upper.startsWith('01')) return -1;
    final value = int.tryParse(upper.substring(2), radix: 16);
    if (value == null || value < 0 || value > 255) return -1;
    return value;
  }
}
