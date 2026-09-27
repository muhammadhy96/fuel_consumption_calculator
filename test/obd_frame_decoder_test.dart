// Unit tests for the pure OBD-II frame decoder.
//
// [ObdFrameDecoder] is deliberately hardware-free: no Bluetooth, no plugin, no
// mocks. Every expected value below is derived from the SAE J1979 formula for
// the PID in question and the arithmetic is written out in a comment, so a
// reviewer can check it against the standard without running anything.
//
// Payload shape note: in production the transport hands the decoder
// `'<command>: <response>'`. Because `ObdService` writes straight to
// `connection.output` the plugin's `lastetCommand` stays empty, so real
// payloads look like `': 410C1AF8'`. Tests use that shape wherever the prefix
// matters and bare hex elsewhere.

import 'package:flutter_test/flutter_test.dart';

import 'package:fuel_consumption_calculator/core/utils/obd_frame_decoder.dart';

const ObdFrameDecoder decoder = ObdFrameDecoder();

/// Asserts that [result] decoded exactly [expected] — no more keys, no fewer —
/// and that every value matches to within [tolerance].
void expectValues(
  ObdDecodeResult result,
  Map<String, double> expected, {
  double tolerance = 1e-9,
}) {
  expect(
    result.values.keys.toSet(),
    expected.keys.toSet(),
    reason: 'decoded PID set mismatch (values: ${result.values})',
  );
  for (final entry in expected.entries) {
    expect(
      result.values[entry.key],
      closeTo(entry.value, tolerance),
      reason: 'value for ${entry.key}',
    );
  }
}

/// One row of the single-PID decode table.
class PidCase {
  const PidCase(this.formula, this.payload, this.key, this.expected);

  /// The J1979 arithmetic, spelled out for review.
  final String formula;
  final String payload;
  final String key;
  final double expected;
}

void main() {
  group('single-PID mode-01 responses', () {
    const cases = <PidCase>[
      // 010C RPM = ((A * 256) + B) / 4
      //   A=0x1A=26, B=0xF8=248 -> ((26*256)+248)/4 = 6904/4 = 1726
      PidCase('((0x1A*256)+0xF8)/4 = 1726', ': 410C1AF8', '010C', 1726.0),
      // 010D speed = A  ->  0x3C = 60 km/h
      PidCase('0x3C = 60', ': 410D3C', '010D', 60.0),
      // 010B MAP = A  ->  0x62 = 98 kPa
      PidCase('0x62 = 98', ': 410B62', '010B', 98.0),
      // 0110 MAF = ((A * 256) + B) / 100
      //   A=0x1A=26, B=0x2C=44 -> ((26*256)+44)/100 = 6700/100 = 67
      PidCase('((0x1A*256)+0x2C)/100 = 67', ': 41101A2C', '0110', 67.0),
      // 0104 engine load = A * 100 / 255  ->  128*100/255 = 50.19607843137255
      PidCase('0x80*100/255 = 50.196078...', ': 410480', '0104',
          50.196078431372548),
      // 010F IAT = A - 40 (degC) -> Kelvin = A - 40 + 273.15
      //   0x32 = 50 -> 50-40+273.15 = 283.15 K (10 degC)
      PidCase('0x32-40+273.15 = 283.15', ': 410F32', '010F', 283.15),
      // 0105 coolant = A - 40 (degC) -> 0x5A = 90 -> 90-40+273.15 = 323.15 K
      PidCase('0x5A-40+273.15 = 323.15', ': 41055A', '0105', 323.15),
      // 010F at the bottom of the range: 0x00 -> -40 degC -> 233.15 K
      PidCase('0x00-40+273.15 = 233.15', ': 410F00', '010F', 233.15),
      // 0111 throttle = A * 100 / 255 -> 0x2D=45 -> 4500/255 = 17.6470588...
      PidCase('0x2D*100/255 = 17.647058...', ': 41112D', '0111',
          17.647058823529413),
      // 0104 at full scale: 0xFF*100/255 = 100 %
      PidCase('0xFF*100/255 = 100', ': 4104FF', '0104', 100.0),
      // 0142 module voltage = ((A * 256) + B) / 1000
      //   A=0x37=55, B=0x08=8 -> ((55*256)+8)/1000 = 14088/1000 = 14.088 V
      PidCase('((0x37*256)+0x08)/1000 = 14.088', ': 41423708', '0142', 14.088),
      // 0144 lambda = ((A * 256) + B) / 32768
      //   A=0x80, B=0x00 -> 32768/32768 = 1.0 (stoichiometric)
      PidCase('((0x80*256)+0x00)/32768 = 1.0', ': 41448000', '0144', 1.0),
      // 0144 one LSB lean of stoich: 32767/32768 = 0.999969482421875
      PidCase('((0x7F*256)+0xFF)/32768 = 0.99996948...', ': 41447FFF', '0144',
          0.999969482421875),
      // 012F fuel level = A * 100 / 255 -> 0x40=64 -> 6400/255 = 25.098039...
      PidCase('0x40*100/255 = 25.098039...', ': 412F40', '012F',
          25.098039215686274),
      // 0133 barometric pressure = A -> 0x65 = 101 kPa
      PidCase('0x65 = 101', ': 413365', '0133', 101.0),
      // 0106/0107 fuel trim = A*100/128 - 100 -> 0x88 = +6.25 %, 0x7C = -3.125 %
      PidCase('0x88*100/128-100 = 6.25', ': 410688', '0106', 6.25),
      PidCase('0x7C*100/128-100 = -3.125', ': 41077C', '0107', -3.125),
      // 0103 fuel system status: bank-1 byte A is kept raw
      PidCase('bank 1 = 0x04', ': 41030400', '0103', 4.0),
      // 0143 absolute load = ((A*256)+B)*100/255 -> 0x0066 = 102 -> 40 %
      PidCase('((0x00*256)+0x66)*100/255 = 40', ': 41430066', '0143', 40.0),
      // 015E fuel rate: L/h = ((A*256)+B)/20, then mL/s = L/h * 1000 / 3600
      //   A=0x07, B=0x08 -> 1800/20 = 90 L/h -> 90*1000/3600 = 25 mL/s
      PidCase('((0x07*256)+0x08)/20 = 90 L/h -> 25 mL/s', ': 415E0708', '015E',
          25.0),
      // 015E idle-ish: 0x00,0x14 = 20 -> 20/20 = 1 L/h -> 1000/3600 mL/s
      PidCase('((0x00*256)+0x14)/20 = 1 L/h -> 0.2777... mL/s', ': 415E0014',
          '015E', 0.27777777777777779),
    ];

    for (final testCase in cases) {
      test('${testCase.key}: ${testCase.formula}', () {
        expectValues(
          decoder.decode(testCase.payload),
          {testCase.key: testCase.expected},
        );
      });
    }

    test('a data byte that happens to be 0x41 is not mistaken for a header',
        () {
      // 41 0C 41 41 -> RPM = ((0x41*256)+0x41)/4 = (16640+65)/4 = 16705/4
      expectValues(decoder.decode(': 410C4141'), {'010C': 4176.25});
    });

    test('0x41 inside a one-byte group is consumed as data', () {
      // 41 | 0D 41 -> speed = 0x41 = 65 km/h, not a new block header.
      expectValues(decoder.decode(': 410D41'), {'010D': 65.0});
    });

    test('lowercase hex and embedded spaces decode identically', () {
      expectValues(decoder.decode(': 41 0c 1a f8'), {'010C': 1726.0});
    });

    test('a payload with no command prefix still decodes', () {
      expectValues(decoder.decode('410C1AF8'), {'010C': 1726.0});
    });

    test('a payload with a real command echoed in the prefix still decodes',
        () {
      expectValues(decoder.decode('01 0C: 410C1AF8'), {'010C': 1726.0});
    });
  });

  group('bulk multi-PID responses (the poll hot path)', () {
    // PidSupport.buildBulkCommands turns the 11 pollPidKeys into
    //   '01 0C 0D 0B 10 04 0F'  and  '01 05 44 11 42 2F'.
    // Both replies are longer than the 7 data bytes a single CAN frame can
    // carry, so the ECU sends them as ISO-TP multi-frame and the ELM327 prints
    // a 3-digit total-length line followed by sequence-tagged frame lines.
    // obd2_plugin removes CR and LF without substituting anything, so those
    // markers reach the decoder glued to the data.

    test('short bulk reply that fits in one CAN frame', () {
      // 41 | 0C 1A F8 | 0D 3C  = 6 data bytes -> one unadorned line.
      expectValues(decoder.decode(': 410C1AF80D3C'), {
        '010C': 1726.0, // ((0x1A*256)+0xF8)/4
        '010D': 60.0, // 0x3C
      });
    });

    test('6-PID reply as an ELM327 multi-frame response', () {
      // Request: 01 0C 0D 0B 10 04 0F
      // Data (15 = 0x00F bytes):
      //   41 0C 1A F8 0D 3C 0B 62 10 1A 2C 04 80 0F 32
      // On the wire the adapter prints:
      //   00F
      //   0:410C1AF80D3C          <- ISO-TP first frame, 6 data bytes
      //   1:0B62101A2C0480        <- consecutive frame, 7 data bytes
      //   2:0F32AAAAAAAAAA        <- 2 data bytes + 0xAA CAN padding
      const payload = ': 00F0:410C1AF80D3C1:0B62101A2C04802:0F32AAAAAAAAAA';
      expectValues(decoder.decode(payload), {
        '010C': 1726.0, // ((0x1A*256)+0xF8)/4    = 6904/4
        '010D': 60.0, // 0x3C
        '010B': 98.0, // 0x62
        '0110': 67.0, // ((0x1A*256)+0x2C)/100  = 6700/100
        '0104': 50.196078431372548, // 0x80*100/255 = 12800/255
        '010F': 283.15, // 0x32-40+273.15
      });
    });

    test('trailing 0xAA CAN padding is dropped, not decoded as PIDs', () {
      const payload = ': 00F0:410C1AF80D3C1:0B62101A2C04802:0F32AAAAAAAAAA';
      final result = decoder.decode(payload);
      expect(result.values.length, 6);
      expect(result.supportBitmasks, isEmpty);
    });

    test('second bulk command as an ELM327 multi-frame response', () {
      // Request: 01 05 44 11 42 2F
      // Data (13 = 0x00D bytes):
      //   41 05 5A 44 80 00 11 2D 42 37 08 2F 40
      //   00D
      //   0:41055A448000          <- 6 data bytes
      //   1:112D4237082F40        <- 7 data bytes, no padding needed
      const payload = ': 00D0:41055A4480001:112D4237082F40';
      expectValues(decoder.decode(payload), {
        '0105': 323.15, // 0x5A-40+273.15
        '0144': 1.0, // ((0x80*256)+0x00)/32768
        '0111': 17.647058823529413, // 0x2D*100/255 = 4500/255
        '0142': 14.088, // ((0x37*256)+0x08)/1000
        '012F': 25.098039215686274, // 0x40*100/255 = 6400/255
      });
    });

    test('multi-frame reply carrying the direct fuel-rate PID', () {
      // Request: 01 0C 0D 5E
      // Data (9 = 0x009 bytes): 41 0C 1A F8 0D 3C 5E 07 08
      //   009
      //   0:410C1AF80D3C
      //   1:5E0708AAAAAAAA
      const payload = ': 0090:410C1AF80D3C1:5E0708AAAAAAAA';
      expectValues(decoder.decode(payload), {
        '010C': 1726.0,
        '010D': 60.0,
        '015E': 25.0, // ((0x07*256)+0x08)/20 = 90 L/h -> 90000/3600
      });
    });

    test('multi-frame reply still decodes with adapter spaces left on', () {
      // Same reply as above but with AT S0 never applied, so the adapter
      // separates bytes with spaces. The sequence tag is still the character
      // immediately in front of each colon.
      const payload =
          ': 00F0: 41 0C 1A F8 0D 3C1: 0B 62 10 1A 2C 04 802: 0F 32 AA AA AA';
      expectValues(decoder.decode(payload), {
        '010C': 1726.0,
        '010D': 60.0,
        '010B': 98.0,
        '0110': 67.0,
        '0104': 50.196078431372548,
        '010F': 283.15,
      });
    });

    test('multi-frame reply that arrived without the command prefix', () {
      // Here the first colon in the string is a frame tag rather than the
      // `command: ` separator, so the leading segment is real data and must not
      // be discarded as a length header.
      const payload = '00F0:410C1AF80D3C1:0B62101A2C04802:0F32AAAAAAAAAA';
      expectValues(decoder.decode(payload), {
        '010C': 1726.0,
        '010D': 60.0,
        '010B': 98.0,
        '0110': 67.0,
        '0104': 50.196078431372548,
        '010F': 283.15,
      });
    });

    test('a bulk reply decodes each PID exactly as its single-PID reply would',
        () {
      const bulk = ': 00F0:410C1AF80D3C1:0B62101A2C04802:0F32AAAAAAAAAA';
      final bulkValues = decoder.decode(bulk).values;
      const singles = <String, String>{
        '010C': ': 410C1AF8',
        '010D': ': 410D3C',
        '010B': ': 410B62',
        '0110': ': 41101A2C',
        '0104': ': 410480',
        '010F': ': 410F32',
      };
      singles.forEach((key, payload) {
        expect(
          bulkValues[key],
          decoder.decode(payload).values[key],
          reason: '$key differs between bulk and single-PID decode',
        );
      });
    });

    test('a truncated multi-frame reply keeps the frames that did arrive', () {
      // The adapter timed out after frame 1, so the tail never came.
      const payload = ': 00F0:410C1AF80D3C1:0B62101A2C0480';
      expectValues(decoder.decode(payload), {
        '010C': 1726.0,
        '010D': 60.0,
        '010B': 98.0,
        '0110': 67.0,
        '0104': 50.196078431372548,
      });
    });

    test('non-CAN bus-init chatter before the frame does not shift the hex',
        () {
      // Slow-init protocols print `BUS INIT: OK` ahead of the reply, and its
      // colon must not be read as a frame tag.
      expectValues(decoder.decode(': BUS INIT: OK410C1AF8'), {'010C': 1726.0});
    });
  });

  group('multiple 0x41 blocks in one payload', () {
    test('two blocks both decode', () {
      // 41 0C 1A F8 | 41 0D 3C  — the inner run stops at the next 0x41.
      expectValues(decoder.decode(': 410C1AF8410D3C'), {
        '010C': 1726.0,
        '010D': 60.0,
      });
    });

    test('three blocks, last one truncated, first two survive', () {
      // 41 0C 1A F8 | 41 0D 3C | 41 42 37   (0142 wants 2 data bytes, has 1)
      expectValues(decoder.decode(': 410C1AF8410D3C414237'), {
        '010C': 1726.0,
        '010D': 60.0,
      });
    });

    test('a later block overwrites an earlier value for the same PID', () {
      // Same PID twice: the last one wins, matching "latest sample" semantics.
      expectValues(decoder.decode(': 410D3C410D50'), {'010D': 80.0}); // 0x50
    });

    test('two ECUs answering the same request collapse to the last value', () {
      // Headers off, two responders: the lines concatenate into two blocks and
      // the second one wins.
      expectValues(decoder.decode(': 410C1AF8410C0FA0'), {
        '010C': 1000.0, // ((0x0F*256)+0xA0)/4 = (3840+160)/4 = 4000/4
      });
    });
  });

  group('supported-PID bitmasks', () {
    test('range 0x00 is captured as a bitmask, not as telemetry', () {
      // 41 00 BE 3E B8 13 — the classic "01 00" answer.
      final result = decoder.decode(': 4100BE3EB813');
      expect(result.supportBitmasks[0x00], [0xBE, 0x3E, 0xB8, 0x13]);
      expect(result.values, isEmpty);
      expect(result.isEmpty, isFalse);
    });

    test('range 0x20 is captured', () {
      final result = decoder.decode(': 41209007E011');
      expect(result.supportBitmasks[0x20], [0x90, 0x07, 0xE0, 0x11]);
      expect(result.values, isEmpty);
    });

    test('range 0x40 is captured', () {
      final result = decoder.decode(': 4140FED08404');
      expect(result.supportBitmasks[0x40], [0xFE, 0xD0, 0x84, 0x04]);
      expect(result.values, isEmpty);
    });

    test('all three ranges in one payload', () {
      final result =
          decoder.decode(': 4100BE3EB81341209007E0114140FED08404');
      expect(result.supportBitmasks.length, 3);
      expect(result.supportBitmasks[0x00], [0xBE, 0x3E, 0xB8, 0x13]);
      expect(result.supportBitmasks[0x20], [0x90, 0x07, 0xE0, 0x11]);
      expect(result.supportBitmasks[0x40], [0xFE, 0xD0, 0x84, 0x04]);
      expect(result.values, isEmpty);
    });

    test('bitmask bytes that look like block headers are still bitmask bytes',
        () {
      // 41 00 41 41 41 41 — every mask byte is 0x41. The bitmask branch must
      // win, otherwise the payload dissolves into empty blocks.
      final result = decoder.decode(': 410041414141');
      expect(result.supportBitmasks[0x00], [0x41, 0x41, 0x41, 0x41]);
      expect(result.values, isEmpty);
    });

    test('a bitmask block followed by a telemetry block decodes both', () {
      final result = decoder.decode(': 4100BE3EB813410C1AF8');
      expect(result.supportBitmasks[0x00], [0xBE, 0x3E, 0xB8, 0x13]);
      expectValues(result, {'010C': 1726.0});
    });

    test('a telemetry block followed by a bitmask block decodes both', () {
      final result = decoder.decode(': 410C1AF84100BE3EB813');
      expect(result.supportBitmasks[0x00], [0xBE, 0x3E, 0xB8, 0x13]);
      expectValues(result, {'010C': 1726.0});
    });

    test('a short bitmask block (fewer than 4 data bytes) is dropped, not read',
        () {
      // 41 00 BE 3E — only 2 bitmask bytes. Falling back to telemetry finds PID
      // byte 0x00, which we do not decode, so the block aborts. No throw, no
      // bogus bitmask entry.
      final result = decoder.decode(': 4100BE3E');
      expect(result.supportBitmasks, isEmpty);
      expect(result.values, isEmpty);
      expect(result.isEmpty, isTrue);
    });
  });

  group('mode 22 (manufacturer-extended)', () {
    test('22 01 01 maps onto extended MAF (0110)', () {
      // 62 01 01 1A 2C -> ((0x1A*256)+0x2C)/100 = 6700/100 = 67 g/s
      expectValues(decoder.decode(': 6201011A2C'), {'0110': 67.0});
    });

    test('a mode-22 group ahead of a mode-01 block: both decode', () {
      // 62 01 01 1A 2C -> 0110 = 67 g/s, then 41 | 0D 3C -> 60 km/h.
      expectValues(decoder.decode(': 6201011A2C410D3C'), {
        '0110': 67.0,
        '010D': 60.0,
      });
    });

    test('a truncated 22 01 01 group decodes nothing and does not throw', () {
      // 62 01 01 1A — the low byte is missing.
      expect(decoder.decode(': 6201011A').isEmpty, isTrue);
    });

    test('an unrelated mode-22 group is skipped without throwing', () {
      // 62 05 00 FF — not 22 01 01, so the group is stepped over.
      expect(decoder.decode(': 620500FF').isEmpty, isTrue);
    });

    test('a two-byte 0x62 fragment does not read past the buffer', () {
      expect(decoder.decode(': 6201').isEmpty, isTrue);
    });
  });

  group('malformed input must never throw', () {
    test('empty string', () {
      final result = decoder.decode('');
      expect(result.values, isEmpty);
      expect(result.supportBitmasks, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('whitespace only', () {
      expect(decoder.decode('   ').isEmpty, isTrue);
    });

    test('command prefix with an empty response', () {
      expect(decoder.decode(': ').isEmpty, isTrue);
    });

    test('a lone colon', () {
      expect(decoder.decode(':').isEmpty, isTrue);
    });

    test('nothing but colons terminates and decodes nothing', () {
      expect(decoder.decode(':::::').isEmpty, isTrue);
    });

    test('truncated final group keeps the groups that came before it', () {
      // 41 | 0C 1A F8 | 0D  — speed's data byte never arrived.
      expectValues(decoder.decode(': 410C1AF80D'), {'010C': 1726.0});
    });

    test('a single truncated group decodes nothing', () {
      // 41 | 0C 1A  — RPM needs 2 data bytes, only 1 present.
      expect(decoder.decode(': 410C1A').isEmpty, isTrue);
    });

    test('a bare 0x41 with no payload decodes nothing', () {
      expect(decoder.decode(': 41').isEmpty, isTrue);
    });

    test('unknown PID byte mid-block aborts only that block', () {
      // 41 0C 1A F8 99 99 | 41 0D 3C
      // 0x99 is not a PID we decode, so the rest of that block is unaligned
      // garbage and is skipped — but the next 0x41 block still decodes.
      expectValues(decoder.decode(': 410C1AF89999410D3C'), {
        '010C': 1726.0,
        '010D': 60.0,
      });
    });

    test('unknown PID byte with no following block loses only the tail', () {
      expectValues(decoder.decode(': 410C1AF899993C'), {'010C': 1726.0});
    });

    test('PID byte 0x00 mid-block aborts the block without a bitmask entry',
        () {
      // 41 0C 1A F8 00 BE 3E B8 13 — the bitmask branch only triggers directly
      // after the 0x41 header, so 0x00 here is just an undecodable PID byte.
      final result = decoder.decode(': 410C1AF800BE3EB813');
      expect(result.supportBitmasks, isEmpty);
      expectValues(result, {'010C': 1726.0});
    });

    test('CAN header garbage before the block is skipped', () {
      // 7E 81 06 | 41 0C 1A F8 — leading bytes are not 0x41/0x62, so the
      // scanner walks over them one byte at a time.
      expectValues(decoder.decode(': 7E8106410C1AF8'), {'010C': 1726.0});
    });

    test('stray PID bytes outside a 0x41 block are ignored', () {
      // 0C 1A F8 | 41 0D 3C — only the block after 0x41 is telemetry, so RPM
      // must NOT appear even though 0C 1A F8 looks like a valid group.
      expectValues(decoder.decode(': 0C1AF8410D3C'), {'010D': 60.0});
    });

    test('a negative response (7F) decodes nothing', () {
      // 7F 01 12 — "sub-function not supported" for mode 01.
      expect(decoder.decode(': 7F0112').isEmpty, isTrue);
    });

    test('misaligned CAN header (odd nibble count) decodes nothing, no throw',
        () {
      // '7E8 03 41 0C 1A F8' with headers accidentally left on: the 3-nibble
      // CAN id shifts every later byte, so nothing lines up. The contract is
      // that we return an empty result rather than inventing values.
      final result = decoder.decode(': 7E8 03 41 0C 1A F8');
      expect(result.isEmpty, isTrue);
    });

    test('odd-length hex drops the trailing nibble', () {
      // '410C1AF8' + a dangling 'A'
      expectValues(decoder.decode(': 410C1AF8A'), {'010C': 1726.0});
    });

    test('a lone hex digit yields no bytes', () {
      expect(decoder.decode(': 4').isEmpty, isTrue);
    });

    test('ELM327 error strings decode to nothing', () {
      // These reach the decoder only if a caller forgets to filter them, so
      // they must degrade to "nothing decodable" rather than throwing or
      // fabricating telemetry.
      for (final error in <String>[
        ': NO DATA',
        ': ?',
        ': STOPPED',
        ': UNABLE TO CONNECT',
        ': BUS ERROR',
        ': CAN ERROR',
        ': ERROR',
        ': OK',
        ': ELM327 v1.5',
      ]) {
        expect(
          decoder.decode(error).isEmpty,
          isTrue,
          reason: 'decoded something from "$error"',
        );
      }
    });

    test('non-hex noise around a valid frame is stripped', () {
      expectValues(
        decoder.decode('01 0C: >[41]-[0C]-[1A]-[F8]<'),
        {'010C': 1726.0},
      );
    });

    test('a long run of 0x41 bytes terminates', () {
      // Pathological: every byte is a block header. Must not loop forever.
      expect(decoder.decode(': ${'41' * 200}').isEmpty, isTrue);
    });

    test('a long run of unknown bytes terminates', () {
      expect(decoder.decode(': ${'99' * 200}').isEmpty, isTrue);
    });

    test('a long run of frame tags terminates', () {
      expect(decoder.decode(': ${'1:' * 200}').isEmpty, isTrue);
    });
  });

  group('parseHexBytes', () {
    test('pairs hex digits and strips everything else', () {
      expect(ObdFrameDecoder.parseHexBytes('41 0C 1A F8'),
          [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('accepts lower case', () {
      expect(ObdFrameDecoder.parseHexBytes('deadbeef'),
          [0xDE, 0xAD, 0xBE, 0xEF]);
    });

    test('discards a trailing odd nibble', () {
      expect(ObdFrameDecoder.parseHexBytes('41 0C 1'), [0x41, 0x0C]);
    });

    test('non-hex letters are removed, not treated as separators', () {
      // 'Z' vanishes, so '4' and '1' pair up across it.
      expect(ObdFrameDecoder.parseHexBytes('4Z1'), [0x41]);
    });

    test('empty input yields no bytes', () {
      expect(ObdFrameDecoder.parseHexBytes(''), isEmpty);
      expect(ObdFrameDecoder.parseHexBytes('hi!'), isEmpty);
    });
  });
}
