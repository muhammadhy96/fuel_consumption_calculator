import '../constants/obd_pids.dart';

/// Decodes the response from OBD supported-PIDs queries (01 00, 01 20, 01 40)
/// into a set of canonical PID keys (e.g. '010C', '010D').
///
/// Each query returns a 4-byte bitmask. The ECU encodes support for 32 PIDs per
/// range. For example, 01 00 covers PIDs 0x01–0x20; bit 0 of the first byte is
/// PID 0x01, bit 7 of the last byte is PID 0x20.
class PidSupport {
  PidSupport();

  static final RegExp _nonHex = RegExp(r'[^0-9a-fA-F]');

  final Set<String> _supported = {};
  bool _parsed = false;

  bool get parsed => _parsed;
  Set<String> get supportedPids => Set.unmodifiable(_supported);

  bool isSupported(String pid) => _supported.contains(pid.toUpperCase());

  /// Attempts to parse a raw hex response string from a supported-PID query.
  ///
  /// [rangeStart] is the first PID in the block (0x00, 0x20, or 0x40) — this
  /// is the PID we asked about, and the response is a 32-bit bitmask of the
  /// next 32 PIDs starting at `rangeStart + 1`.
  void parseRange(int rangeStart, List<int> dataBytes) {
    if (dataBytes.length < 4) return;
    _parsed = true;
    for (var byteIndex = 0; byteIndex < 4; byteIndex++) {
      final byte = dataBytes[byteIndex];
      for (var bit = 7; bit >= 0; bit--) {
        if ((byte >> bit) & 1 == 1) {
          final pidNumber = rangeStart + 1 + (byteIndex * 8) + (7 - bit);
          final pidKey =
              '01${pidNumber.toRadixString(16).padLeft(2, '0')}'.toUpperCase();
          _supported.add(pidKey);
        }
      }
    }
  }

  /// Parses a raw hex payload (e.g. `41 00 BE 3E B8 13`) from the ELM327. Each
  /// block is the mode echo (41), the PID echo (00/20/40) and a 4-byte
  /// bitmask. With headers off, every ECU that answers (engine, gearbox, ...)
  /// appends its own block in no guaranteed order, so all of them are merged.
  void parseRawResponse(String raw) {
    // Status words such as `BUS INIT: ...OK` or `SEARCHING...` contain hex
    // letters (B, C, E) that would shift the byte alignment.
    final cleaned =
        raw.replaceAll(_statusWord, '').replaceAll(_nonHex, '');
    final bytes = <int>[];
    for (var i = 0; i + 1 < cleaned.length; i += 2) {
      final v = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (v != null) bytes.add(v);
    }
    var i = 0;
    while (i + 6 <= bytes.length) {
      final rangePid = bytes[i + 1];
      if (bytes[i] == 0x41 &&
          (rangePid == 0x00 || rangePid == 0x20 || rangePid == 0x40)) {
        parseRange(rangePid, bytes.sublist(i + 2, i + 6));
        i += 6;
      } else {
        i += 1;
      }
    }
  }

  /// A run of letters containing at least one non-hex letter.
  static final RegExp _statusWord = RegExp(r'[A-Za-z]*[G-Zg-z][A-Za-z]*');

  /// Filters a list of canonical PID keys to only those the ECU supports.
  /// If no bitmask has been parsed yet, returns the original list (best-effort).
  List<String> filter(List<String> desiredPids) {
    if (!_parsed) return desiredPids;
    return [
      for (final pid in desiredPids)
        if (_supported.contains(pid)) pid,
    ];
  }

  /// True when the bitmask says PID 0x20 (or 0x40) is supported, meaning the
  /// next probe range is worth requesting.
  bool hasNextRange(int rangeStart) {
    final nextPid = rangeStart + 0x20;
    final key = '01${nextPid.toRadixString(16).padLeft(2, '0')}'.toUpperCase();
    return _supported.contains(key);
  }

  /// Splits [pids] into ELM327 bulk mode-01 commands of at most
  /// [maxPidsPerBulkRequest] PIDs each.
  /// e.g. `['010C','010D','010B']` -> `['01 0C 0D 0B']`.
  List<String> buildBulkCommands(List<String> pids) {
    if (pids.isEmpty) return const [];
    final commands = <String>[];
    for (var start = 0; start < pids.length; start += maxPidsPerBulkRequest) {
      final rawEnd = start + maxPidsPerBulkRequest;
      final end = rawEnd < pids.length ? rawEnd : pids.length;
      final buffer = StringBuffer('01');
      for (var i = start; i < end; i++) {
        buffer
          ..write(' ')
          ..write(pids[i].toUpperCase().substring(2));
      }
      commands.add(buffer.toString());
    }
    return commands;
  }

  /// One command per PID, for adapters that reject multi-PID requests.
  /// e.g. `['010C']` -> `['01 0C']`.
  List<String> buildSingleCommands(List<String> pids) {
    if (pids.isEmpty) return const [];
    return [
      for (final pid in pids) '01 ${pid.toUpperCase().substring(2)}',
    ];
  }
}
