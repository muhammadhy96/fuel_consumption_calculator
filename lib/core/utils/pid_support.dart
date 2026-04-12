/// Decodes the response from OBD supported-PIDs queries (01 00, 01 20, 01 40)
/// into a set of canonical PID keys (e.g. '010C', '010D').
///
/// Each query returns a 4-byte bitmask. The ECU encodes support for 32 PIDs per
/// range. For example, 01 00 covers PIDs 0x01–0x20; bit 0 of the first byte is
/// PID 0x01, bit 7 of the last byte is PID 0x20.
class PidSupport {
  PidSupport();

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

  /// Parses a raw hex payload (e.g. `41 00 BE 3E B8 13`) from the ELM327. The
  /// first two bytes are the mode echo (41) and the PID echo (00/20/40); the
  /// remaining 4 bytes are the bitmask.
  void parseRawResponse(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final bytes = <int>[];
    for (var i = 0; i + 1 < cleaned.length; i += 2) {
      final v = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (v != null) bytes.add(v);
    }
    if (bytes.length < 6 || bytes[0] != 0x41) return;
    final rangePid = bytes[1];
    parseRange(rangePid, bytes.sublist(2, 6));
  }

  /// Filters a list of canonical PID keys to only those the ECU supports.
  /// If no bitmask has been parsed yet, returns the original list (best-effort).
  List<String> filter(List<String> desiredPids) {
    if (!_parsed) return desiredPids;
    return [
      for (final pid in desiredPids)
        if (_supported.contains(pid)) pid,
    ];
  }

  /// Builds an OBD multi-PID command string from the filtered PID list.
  /// Strips the "01" mode prefix and space-joins bare PID bytes.
  /// Example: ['010C', '010D', '010B'] → '01 0C 0D 0B'.
  String buildBulkCommand(List<String> pids) {
    if (pids.isEmpty) return '';
    final pidBytes = [
      for (final pid in pids)
        pid.substring(2),
    ];
    return '01 ${pidBytes.join(' ')}';
  }
}
