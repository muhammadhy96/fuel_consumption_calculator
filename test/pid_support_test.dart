// Unit tests for the supported-PID bitmask parser and the bulk command
// builder. Pure Dart — no hardware, no plugins.
//
// Bit ordering is the thing to get right here. A "01 00" reply carries a 32-bit
// mask covering PIDs 0x01..0x20, sent MSB-first:
//
//   byte 0 bit 7 -> PID 0x01        byte 0 bit 0 -> PID 0x08
//   byte 1 bit 7 -> PID 0x09        byte 3 bit 0 -> PID 0x20
//
// An off-by-one here does not crash anything: it silently shifts every PID by
// one, so the poll loop asks for PIDs the ECU never advertised and drops ones
// it did. That is why the mapping is asserted exhaustively below.

import 'package:flutter_test/flutter_test.dart';

import 'package:fuel_consumption_calculator/core/constants/obd_pids.dart';
import 'package:fuel_consumption_calculator/core/utils/pid_support.dart';

/// The mask byte list in which only [bitIndex] (counted MSB-first across the
/// four bytes, so 0 is byte 0 bit 7) is set.
List<int> maskWithOnlyBit(int bitIndex) {
  final bytes = [0, 0, 0, 0];
  bytes[bitIndex ~/ 8] = 1 << (7 - (bitIndex % 8));
  return bytes;
}

String pidKey(int pidNumber) =>
    '01${pidNumber.toRadixString(16).padLeft(2, '0')}'.toUpperCase();

void main() {
  group('parseRange bit ordering', () {
    test('bit 7 of the first byte is PID rangeStart + 1', () {
      final support = PidSupport();
      // 0x80 = 1000 0000 -> only the most significant bit of byte 0.
      support.parseRange(0x00, [0x80, 0x00, 0x00, 0x00]);
      expect(support.supportedPids, {'0101'});
    });

    test('bit 0 of the first byte is PID rangeStart + 8', () {
      final support = PidSupport();
      // 0x01 = 0000 0001 -> the least significant bit of byte 0.
      support.parseRange(0x00, [0x01, 0x00, 0x00, 0x00]);
      expect(support.supportedPids, {'0108'});
    });

    test('bit 7 of the fourth byte is PID rangeStart + 25', () {
      final support = PidSupport();
      support.parseRange(0x00, [0x00, 0x00, 0x00, 0x80]);
      expect(support.supportedPids, {'0119'}); // 0x19 = 25
    });

    test('bit 0 of the fourth byte is PID rangeStart + 32', () {
      final support = PidSupport();
      support.parseRange(0x00, [0x00, 0x00, 0x00, 0x01]);
      expect(support.supportedPids, {'0120'}); // 0x20 = 32
    });

    test('every one of the 32 bits maps to its own PID, range 0x00', () {
      for (var bitIndex = 0; bitIndex < 32; bitIndex++) {
        final support = PidSupport();
        support.parseRange(0x00, maskWithOnlyBit(bitIndex));
        expect(
          support.supportedPids,
          {pidKey(0x00 + 1 + bitIndex)},
          reason: 'bit $bitIndex of the 01 00 mask',
        );
      }
    });

    test('range 0x20 covers PIDs 0x21..0x40', () {
      final first = PidSupport()..parseRange(0x20, maskWithOnlyBit(0));
      expect(first.supportedPids, {'0121'});
      final last = PidSupport()..parseRange(0x20, maskWithOnlyBit(31));
      expect(last.supportedPids, {'0140'});
    });

    test('range 0x40 covers PIDs 0x41..0x60', () {
      final first = PidSupport()..parseRange(0x40, maskWithOnlyBit(0));
      expect(first.supportedPids, {'0141'});
      final last = PidSupport()..parseRange(0x40, maskWithOnlyBit(31));
      expect(last.supportedPids, {'0160'});
    });

    test('an all-ones mask reports exactly PIDs 0x01..0x20', () {
      final support = PidSupport();
      support.parseRange(0x00, [0xFF, 0xFF, 0xFF, 0xFF]);
      expect(support.supportedPids.length, 32);
      for (var pid = 0x01; pid <= 0x20; pid++) {
        expect(support.isSupported(pidKey(pid)), isTrue, reason: 'PID $pid');
      }
    });

    test('an all-zero mask supports nothing but still counts as parsed', () {
      // This is what makes ObdService union essentialPidKeys back in: an ECU
      // that answers 01 00 with zeros must not silence the whole poll loop by
      // accident.
      final support = PidSupport();
      support.parseRange(0x00, [0x00, 0x00, 0x00, 0x00]);
      expect(support.parsed, isTrue);
      expect(support.supportedPids, isEmpty);
    });

    test('ranges accumulate instead of replacing each other', () {
      final support = PidSupport()
        ..parseRange(0x00, maskWithOnlyBit(11)) // PID 0x0C
        ..parseRange(0x20, maskWithOnlyBit(30)) // PID 0x20 + 31 = 0x3F
        ..parseRange(0x40, maskWithOnlyBit(29)); // PID 0x40 + 30 = 0x5E
      expect(support.supportedPids, {'010C', '013F', '015E'});
    });

    test('a mask shorter than 4 bytes is ignored entirely', () {
      final support = PidSupport();
      support.parseRange(0x00, [0xFF, 0xFF, 0xFF]);
      expect(support.parsed, isFalse);
      expect(support.supportedPids, isEmpty);
    });

    test('extra mask bytes past the fourth are ignored', () {
      final support = PidSupport();
      support.parseRange(0x00, [0x80, 0x00, 0x00, 0x00, 0xFF, 0xFF]);
      expect(support.supportedPids, {'0101'});
    });
  });

  group('parseRawResponse', () {
    // 41 00 BE 3E B8 13 is the canonical "01 00" answer of a MAP-based car.
    //   0xBE = 1011 1110 -> PIDs 01, 03, 04, 05, 06, 07
    //   0x3E = 0011 1110 -> PIDs 0B, 0C, 0D, 0E, 0F      (byte 1 base = 09)
    //   0xB8 = 1011 1000 -> PIDs 11, 13, 14, 15          (byte 2 base = 11)
    //   0x13 = 0001 0011 -> PIDs 1C, 1F, 20              (byte 3 base = 19)
    const expectedFromBe3eb813 = <String>{
      '0101', '0103', '0104', '0105', '0106', '0107', //
      '010B', '010C', '010D', '010E', '010F', //
      '0111', '0113', '0114', '0115', //
      '011C', '011F', '0120',
    };

    test('parses the mode/PID echo and the four mask bytes', () {
      final support = PidSupport()..parseRawResponse('4100BE3EB813');
      expect(support.supportedPids, expectedFromBe3eb813);
      // MAF is genuinely absent from this mask — that is the whole point of the
      // essentialPidKeys union in ObdService.
      expect(support.isSupported('0110'), isFalse);
    });

    test('spaces, the transport prefix and lower case are all tolerated', () {
      // ObdService feeds this the payload with the `command: ` prefix removed,
      // which leaves a leading space.
      final support = PidSupport()..parseRawResponse(' 41 00 be 3e b8 13');
      expect(support.supportedPids, expectedFromBe3eb813);
    });

    test('trailing bytes after the mask are ignored', () {
      final support = PidSupport()..parseRawResponse('4100BE3EB81300FFFF');
      expect(support.supportedPids, expectedFromBe3eb813);
    });

    test('a response that is not a mode-01 reply is rejected', () {
      final support = PidSupport()..parseRawResponse('7F0112');
      expect(support.parsed, isFalse);
      expect(support.supportedPids, isEmpty);
    });

    test('a truncated mask is rejected', () {
      final support = PidSupport()..parseRawResponse('4100BE3E');
      expect(support.parsed, isFalse);
      expect(support.supportedPids, isEmpty);
    });

    test('error strings and empty input are rejected without throwing', () {
      for (final raw in <String>['', '   ', 'NO DATA', '?', 'STOPPED', 'OK']) {
        final support = PidSupport()..parseRawResponse(raw);
        expect(support.parsed, isFalse, reason: 'accepted "$raw"');
        expect(support.supportedPids, isEmpty, reason: 'accepted "$raw"');
      }
    });

    test('range 0x20 and 0x40 replies land in the right ranges', () {
      final support = PidSupport()
        ..parseRawResponse('412080000000') // byte 0 bit 7 of range 0x20
        ..parseRawResponse('414080000000'); // byte 0 bit 7 of range 0x40
      expect(support.supportedPids, {'0121', '0141'});
    });
  });

  group('isSupported / supportedPids', () {
    test('lookup is case-insensitive', () {
      final support = PidSupport()..parseRawResponse('4100BE3EB813');
      expect(support.isSupported('010c'), isTrue);
      expect(support.isSupported('010C'), isTrue);
      expect(support.isSupported('0110'), isFalse);
    });

    test('nothing is supported before a mask has been parsed', () {
      final support = PidSupport();
      expect(support.parsed, isFalse);
      expect(support.isSupported('010C'), isFalse);
      expect(support.supportedPids, isEmpty);
    });

    test('the exposed set cannot be mutated by callers', () {
      final support = PidSupport()..parseRawResponse('4100BE3EB813');
      expect(() => support.supportedPids.add('01FF'), throwsUnsupportedError);
    });
  });

  group('filter', () {
    test('passes the desired list straight through when nothing is parsed', () {
      final support = PidSupport();
      expect(support.filter(pollPidKeys), pollPidKeys);
    });

    test('keeps only supported PIDs and preserves pollPidKeys ordering', () {
      final support = PidSupport()..parseRawResponse('4100BE3EB813');
      // pollPidKeys order is 0C 0D 0B 10 04 0F 05 44 06 07 03 11 42 2F; the
      // mask above supports 0C 0D 0B 04 0F 05 06 07 03 11 and not 10 44 42 2F.
      expect(support.filter(pollPidKeys), [
        '010C',
        '010D',
        '010B',
        '0104',
        '010F',
        '0105',
        '0106',
        '0107',
        '0103',
        '0111',
      ]);
    });

    test('an ECU that advertises nothing filters everything away', () {
      final support = PidSupport()..parseRange(0x00, [0, 0, 0, 0]);
      expect(support.filter(pollPidKeys), isEmpty);
    });

    test('an empty desired list stays empty', () {
      final support = PidSupport()..parseRawResponse('4100BE3EB813');
      expect(support.filter(const []), isEmpty);
    });
  });

  group('hasNextRange', () {
    test('is false before anything is parsed', () {
      final support = PidSupport();
      expect(support.hasNextRange(0x00), isFalse);
      expect(support.hasNextRange(0x20), isFalse);
      expect(support.hasNextRange(0x40), isFalse);
    });

    test('range 0x00 advertising PID 0x20 means 01 20 is worth asking', () {
      // 0x13's bit 0 is PID 0x20 — see the mask breakdown above.
      final support = PidSupport()..parseRawResponse('4100BE3EB813');
      expect(support.isSupported('0120'), isTrue);
      expect(support.hasNextRange(0x00), isTrue);
      // Nothing has claimed PID 0x40 yet, so 01 40 must not be requested.
      expect(support.hasNextRange(0x20), isFalse);
    });

    test('range 0x20 advertising PID 0x40 unlocks the 01 40 probe', () {
      final support = PidSupport()
        ..parseRange(0x20, [0x00, 0x00, 0x00, 0x01]); // PID 0x40
      expect(support.isSupported('0140'), isTrue);
      expect(support.hasNextRange(0x20), isTrue);
    });

    test('a mask that stops short of the boundary PID stops the probing', () {
      // Bit 1 of byte 3 is PID 0x1F, one short of 0x20.
      final support = PidSupport()..parseRange(0x00, [0x00, 0x00, 0x00, 0x02]);
      expect(support.supportedPids, {'011F'});
      expect(support.hasNextRange(0x00), isFalse);
    });

    test('hasNextRange(0x40) looks for PID 0x60', () {
      final support = PidSupport()..parseRange(0x40, maskWithOnlyBit(31));
      expect(support.supportedPids, {'0160'});
      expect(support.hasNextRange(0x40), isTrue);
    });
  });

  group('buildBulkCommands', () {
    final support = PidSupport();

    test('packs the 15 poll PIDs into three commands, chunked at 6', () {
      expect(maxPidsPerBulkRequest, 6);
      expect(support.buildBulkCommands(pollPidKeys), [
        '01 0C 0D 0B 10 04 0F',
        '01 05 44 06 07 03 11',
        '01 42 43 2F',
      ]);
    });

    test('exactly 6 PIDs stay in one command', () {
      expect(
        support.buildBulkCommands(
          const ['010C', '010D', '010B', '0110', '0104', '010F'],
        ),
        ['01 0C 0D 0B 10 04 0F'],
      );
    });

    test('7 PIDs split 6 + 1', () {
      expect(
        support.buildBulkCommands(
          const ['010C', '010D', '010B', '0110', '0104', '010F', '0105'],
        ),
        ['01 0C 0D 0B 10 04 0F', '01 05'],
      );
    });

    test('12 PIDs split 6 + 6 and 13 split 6 + 6 + 1', () {
      final twelve = [...pollPidKeys.take(11), '015E'];
      expect(support.buildBulkCommands(twelve).length, 2);
      final thirteen = [...twelve, '0133'];
      final commands = support.buildBulkCommands(thirteen);
      expect(commands.length, 3);
      expect(commands.last, '01 33');
    });

    test('a single PID yields a single well-formed command', () {
      expect(support.buildBulkCommands(const ['010C']), ['01 0C']);
    });

    test('lower-case keys are normalised', () {
      expect(support.buildBulkCommands(const ['010c', '015e']), ['01 0C 5E']);
    });

    test('empty input yields an immutable empty list', () {
      final commands = support.buildBulkCommands(const []);
      expect(commands, isEmpty);
      expect(() => commands.add('01 0C'), throwsUnsupportedError);
    });
  });

  group('buildSingleCommands', () {
    final support = PidSupport();

    test('emits one command per PID', () {
      expect(support.buildSingleCommands(pollPidKeys), [
        '01 0C',
        '01 0D',
        '01 0B',
        '01 10',
        '01 04',
        '01 0F',
        '01 05',
        '01 44',
        '01 06',
        '01 07',
        '01 03',
        '01 11',
        '01 42',
        '01 43',
        '01 2F',
      ]);
    });

    test('lower-case keys are normalised', () {
      expect(support.buildSingleCommands(const ['015e']), ['01 5E']);
    });

    test('empty input yields an immutable empty list', () {
      final commands = support.buildSingleCommands(const []);
      expect(commands, isEmpty);
      expect(() => commands.add('01 0C'), throwsUnsupportedError);
    });

    test('the fallback covers exactly the same PIDs as the bulk form', () {
      final bulk = support.buildBulkCommands(pollPidKeys);
      final singles = support.buildSingleCommands(pollPidKeys);
      String pidsOf(Iterable<String> commands) => commands
          .map((c) => c.substring(2).trim())
          .join(' ')
          .split(RegExp(r'\s+'))
          .join(' ');
      expect(pidsOf(singles), pidsOf(bulk));
    });
  });

  group('poll PID catalogue', () {
    test('every poll PID has a decode length', () {
      for (final pid in [...pollPidKeys, fuelRatePidKey]) {
        expect(pidByteLength.containsKey(pid), isTrue, reason: pid);
      }
    });

    test('the essential PIDs are all part of the poll list', () {
      for (final pid in essentialPidKeys) {
        expect(pollPidKeys.contains(pid), isTrue, reason: pid);
      }
    });

    test('the poll list has no duplicates', () {
      expect(pollPidKeys.toSet().length, pollPidKeys.length);
    });
  });

  group('parseRawResponse with several ECUs', () {
    test('masks from every answering ECU are merged', () {
      // Gearbox (TCM) first, then the engine (ECM), as CAN may deliver them.
      final support = PidSupport()
        ..parseRawResponse('4100800000014100BE3EB813');
      expect(support.isSupported('0101'), isTrue);
      expect(support.isSupported('010C'), isTrue);
      expect(support.isSupported('010F'), isTrue);
      expect(support.isSupported('0120'), isTrue);
    });

    test('a BUS INIT status prefix does not shift the bytes', () {
      final support = PidSupport()
        ..parseRawResponse(' BUS INIT: ...OK4100BE3EB813');
      expect(support.isSupported('010C'), isTrue);
      expect(support.isSupported('010D'), isTrue);
      expect(support.isSupported('0110'), isFalse);
    });

    test('a SEARCHING prefix does not shift the bytes', () {
      final support = PidSupport()
        ..parseRawResponse('SEARCHING...4100BE3EB813');
      expect(support.isSupported('010C'), isTrue);
    });
  });
}
