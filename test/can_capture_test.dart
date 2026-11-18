import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_consumption_calculator/core/services/obd_service.dart';
import 'package:fuel_consumption_calculator/core/services/obd_transport.dart';
import 'package:fuel_consumption_calculator/core/services/storage_service.dart';
import 'package:fuel_consumption_calculator/core/utils/can_monitor.dart';
import 'package:fuel_consumption_calculator/core/utils/obd_frame_decoder.dart';
import 'package:fuel_consumption_calculator/core/utils/trip_integrator.dart';
import 'package:fuel_consumption_calculator/models/trip_sample.dart';

import 'support/fake_elm.dart';

/// In-memory settings, so no Hive box is needed.
class _MemoryStorage extends StorageService {
  final Map<String, String> _settings = {};

  @override
  Future<String?> getSetting(String key) async => _settings[key];

  @override
  Future<void> setSetting(String key, String value) async =>
      _settings[key] = value;

  @override
  Future<void> removeSetting(String key) async => _settings.remove(key);
}

TripSample _sample(double t, double fuelMlPerSec, {int? can}) => TripSample(
      timeSeconds: t,
      rpm: 800,
      mapKpa: 35,
      speedKph: 0,
      iatKelvin: 300,
      fuelMlPerSec: fuelMlPerSec,
      mafGramsPerSec: 0,
      equivRatio: 1,
      canFuelRaw: can,
    );

void main() {
  group('parseMonitorFrames', () {
    test('cuts glued 8-byte frames and drops the line cut by the stop', () {
      final frames = parseMonitorFrames(
        ': 8CA600898C038C038CA700898C038C038CA800STOPPED',
      );
      expect(frames.map(canFrameHex), [
        '8C A6 00 89 8C 03 8C 03',
        '8C A7 00 89 8C 03 8C 03',
      ]);
    });

    test('accepts spaces and ignores adapter messages between frames', () {
      final frames = parseMonitorFrames(
        ': 94 1A 00 89 67 00 5E 00BUFFER FULL94 1B 00 87 67 00 5E 00',
      );
      expect(frames.map((f) => f[1]), [0x1A, 0x1B]);
    });

    test('headered lines prove the filter, or reveal that it leaks', () {
      final ok = parseHeaderedFrames(
        ': 5458CA600898C038C035458CA700898C038C03545STOPPED',
        '545',
      );
      expect(ok!.map((f) => f[1]), [0xA6, 0xA7]);
      expect(
        parseHeaderedFrames(': 316012D240B2C1E005458CA600898C038C03', '545'),
        isNull,
      );
    });

    test('ID-tagged lines are split where byte and next ID meet', () {
      final frames = parseTaggedFrames(
        ': 316 01 2D 24 0B 2C 1E 00545 8C A6 00 89 8C 03 8C 03316 01 2E 29 '
        '0B 2C 1E 00545 8C A7 00 89 8C 03 8C 03545 8C A8 00STOPPED',
        '545',
      );
      expect(frames.map(canFrameHex), [
        '8C A6 00 89 8C 03 8C 03',
        '8C A7 00 89 8C 03 8C 03',
      ]);
    });

    test('yields nothing from a reply without complete frames', () {
      expect(parseMonitorFrames(': STOPPED'), isEmpty);
      expect(parseMonitorFrames(': ?'), isEmpty);
      expect(parseMonitorFrames(': <DATA ERROR<DATA ERRORSTOPPED'), isEmpty);
      expect(parseMonitorFrames(''), isEmpty);
    });
  });

  group('CanFuelSignal', () {
    test('reads bytes 1-2 as one little-endian count', () {
      expect(CanFuelSignal.rawFromFrame([0xAC, 0x1F, 0x00, 0x8A, 0, 0, 0, 0]),
          31);
      // Full load: past 255 the high byte is 1 (the byte-1 build logged 18).
      expect(CanFuelSignal.rawFromFrame([0x8C, 0x12, 0x01, 0x89, 0, 0, 0, 0]),
          274);
      expect(CanFuelSignal.rawFromFrame([0x8C, 0x12]), isNull);
      expect(CanFuelSignal.rawFromHex('8C 12 01 89 2B 03 2B 03'), 274);
      expect(CanFuelSignal.rawFromHex('8C 12'), isNull);
      expect(CanFuelSignal.rawFromHex('ZZ 12 01'), isNull);
      expect(CanFuelSignal.rawFromHex(null), isNull);
    });
  });

  group('TripSample CSV', () {
    test('writes the ECU fuel in mL/s and the capture window', () {
      final s = TripSample(
        timeSeconds: 1.5,
        rpm: 900,
        mapKpa: 30,
        speedKph: 12,
        iatKelvin: 300,
        fuelMlPerSec: 0.2,
        mafGramsPerSec: 0,
        equivRatio: 1,
        canFuelRaw: 274,
        canFrameHex: '8C 12 01 89 2B 03 2B 03',
        canFrameCount: 12,
        canListenMs: 123,
      );
      final row = s.toCsvRow();
      expect(row.length, TripSample.csvColumnCount);
      expect(row[16] as double, closeTo(274 * 0.0128, 1e-9));
      final back = TripSample.fromCsvRow(row);
      expect(back.canFuelRaw, 274);
      expect(back.canFrameCount, 12);
      expect(back.canListenMs, 123);
      expect(back.canFuelMlPerSec, closeTo(3.5072, 1e-9));
      // A 16-column row from the previous build has no window columns.
      final old = TripSample.fromCsvRow(row.sublist(0, 16));
      expect(old.canFuelRaw, 274);
      expect(old.canFrameCount, isNull);
      expect(old.canListenMs, isNull);
      // A cycle without a CAN read writes null cells.
      final none = TripSample.fromCsvRow([
        ...row.sublist(0, 14),
        for (var i = 14; i < TripSample.csvColumnCount; i++) 'null',
      ]);
      expect(none.canFuelRaw, isNull);
      expect(none.canFuelMlPerSec, isNull);
      expect(none.canFrameCount, isNull);
    });

    test('decodes the count again from the stored frame', () {
      final row = _sample(3.0, 3.3, can: 18).toCsvRow();
      row[15] = '8C 12 01 89 2B 03 2B 03';
      // Recorded by the byte-1 build: raw column 18, the frame says 274.
      expect(TripSample.fromCsvRow(row).canFuelRaw, 274);
      row[15] = 'null';
      expect(TripSample.fromCsvRow(row).canFuelRaw, 18);
    });

    test('round-trips the CAN columns and reads older layouts', () {
      final s = TripSample(
        timeSeconds: 1.5,
        rpm: 900,
        mapKpa: 30,
        speedKph: 12,
        iatKelvin: 300,
        fuelMlPerSec: 0.2,
        mafGramsPerSec: 0,
        equivRatio: 1,
        canFuelRaw: 26,
        canFrameHex: '94 1A 00 89 67 00 5E 00',
      );
      final row = s.toCsvRow();
      expect(row.length, TripSample.csvColumnCount);
      final back = TripSample.fromCsvRow(row);
      expect(back.canFuelRaw, 26);
      expect(back.canFrameHex, '94 1A 00 89 67 00 5E 00');

      // A cycle without a CAN read leaves blank cells, as the CSV reads them.
      final blank = TripSample.fromCsvRow([...row.sublist(0, 14), '', '']);
      final written = TripSample.fromCsvRow([...row.sublist(0, 14), 'null', 'null']);
      expect(written.canFuelRaw, isNull);
      expect(written.canFrameHex, isNull);
      expect(blank.canFuelRaw, isNull);
      expect(blank.canFrameHex, isNull);
      expect(TripSample.fromCsvRow(row.sublist(0, 14)).canFuelRaw, isNull);
    });
  });

  group('TripIntegrator CAN totals', () {
    test('integrates the raw byte between reads and the app fuel alongside',
        () {
      final totals = TripIntegrator()
        ..addAll([
          _sample(0.0, 0.2, can: 20),
          _sample(0.5, 0.2),
          _sample(1.0, 0.2, can: 20),
          _sample(1.5, 0.2),
          _sample(2.0, 0.2, can: 40),
          // A 10 s hole in the CAN reads is not bridged.
          _sample(12.0, 0.2, can: 40),
        ]);
      // 20 counts for 1 s + mean 30 counts for 1 s = 50 count-seconds.
      expect(totals.canRawSeconds, closeTo(50, 1e-9));
      expect(totals.canCoveredSeconds, closeTo(2, 1e-9));
      expect(totals.appFuelMlOverCan, closeTo(0.4, 1e-9));
      // 0.128 uL per 10 ms frame = 0.0128 mL/s per count.
      expect(CanFuelSignal.mlPerSecPerCount, closeTo(0.0128, 1e-12));
      expect(totals.canFuelMl, closeTo(50 * 0.0128, 1e-9));
      // No frame counts logged: no period.
      expect(totals.canFramePeriodMs, isNull);
    });

    test('measures the message period from frames per window', () {
      TripSample read(double t, int frames, int ms) => TripSample(
            timeSeconds: t,
            rpm: 800,
            mapKpa: 35,
            speedKph: 0,
            iatKelvin: 300,
            fuelMlPerSec: 0.2,
            mafGramsPerSec: 0,
            equivRatio: 1,
            canFuelRaw: 20,
            canFrameCount: frames,
            canListenMs: ms,
          );
      final totals = TripIntegrator()
        ..addAll([read(0, 12, 125), read(1, 12, 121), read(2, 30, 302)]);
      expect(totals.canFramePeriodMs, closeTo(548 / 54, 1e-9));
    });
  });

  group('ObdService CAN capture against a fake ELM327', () {
    late FakeElm elm;
    late ObdService service;

    setUp(() async {
      elm = await FakeElm.start();
      service = ObdService(_MemoryStorage());
    });

    tearDown(() async {
      await service.disconnect(notify: false);
      await elm.close();
    });

    Future<void> connect() => service.connect(
          ObdDevice.wifi(host: '127.0.0.1', port: elm.port),
        );

    test('reads 0x545 between polls and leaves PID polling intact', () async {
      await connect();
      expect(service.canCaptureActive, isTrue);

      final frames = <List<int>>[];
      final replies = <String>[];
      var cycles = 0;
      service.onCanFrame = frames.add;
      service.onCycleComplete = () => cycles += 1;
      await service.startListening(replies.add);
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      await service.stopListening();

      // About one read a second, each a whole 8-byte frame with the fuel byte.
      expect(frames.length, inInclusiveRange(2, 5));
      for (final f in frames) {
        expect(f.length, 8);
        expect(f[0], 0x8C);
        expect(f[3], 0x89);
      }
      // Newest frame of each read: the fuel count only ever counts up.
      for (var i = 1; i < frames.length; i++) {
        expect(CanFuelSignal.rawFromFrame(frames[i]),
            greaterThan(CanFuelSignal.rawFromFrame(frames[i - 1])!));
      }
      // The adapter is back to OBD settings and no request hit the filter.
      expect(elm.pidRequestsWhileFiltered, 0);
      expect(elm.caf, isTrue);
      expect(elm.cra, isNull);
      expect(elm.headers, isFalse);
      expect(elm.spaces, isFalse);
      expect(service.canFilterHonoured, isTrue);
      // PID polling kept running and decoding.
      expect(cycles, greaterThan(frames.length));
      const decoder = ObdFrameDecoder();
      final rpm = replies
          .map((r) => decoder.decode(r).values['010C'])
          .whereType<double>();
      expect(rpm, isNotEmpty);
      expect(rpm.first, 720);
    });

    test('measures the 0x545 period from the frames in each window', () async {
      elm.frameInterval = const Duration(milliseconds: 50);
      await connect();
      expect(service.canCaptureActive, isTrue);
      final replies = <String>[];
      await service.startListening(replies.add);
      await Future<void>.delayed(const Duration(milliseconds: 3000));
      await service.stopListening();

      expect(service.lastCanFrameCount, greaterThan(1));
      expect(service.lastCanListenMs, greaterThanOrEqualTo(100));
      // Timer resolution on the test host makes the fake's 50 ms inexact.
      expect(service.canFramePeriodMs, isNotNull);
      expect(service.canFramePeriodMs!, inInclusiveRange(30.0, 90.0));
    });

    test('picks 0x545 out of an adapter that ignores its monitor filter',
        () async {
      elm.leaksOtherIds = true;
      await connect();
      expect(service.canCaptureActive, isTrue);
      expect(service.canFilterHonoured, isFalse);

      final frames = <List<int>>[];
      final replies = <String>[];
      service.onCanFrame = frames.add;
      await service.startListening(replies.add);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await service.stopListening();

      expect(frames, isNotEmpty);
      for (final f in frames) {
        expect(canFrameHex(f), matches(r'^8C .. 00 89 2B 03 2B 03$'));
      }
      expect(elm.pidRequestsWhileFiltered, 0);
      expect(elm.headers, isFalse);
      expect(elm.spaces, isFalse);
      expect(elm.caf, isTrue);
      const decoder = ObdFrameDecoder();
      expect(
        replies.map((r) => decoder.decode(r).values['010C']).whereType<double>(),
        isNotEmpty,
      );
    });

    test('stays off for a car without the frame, polling unaffected',
        () async {
      elm.sends545 = false;
      await connect();
      expect(service.canCaptureActive, isFalse);
      expect(elm.cra, isNull);
      expect(elm.caf, isTrue);

      final replies = <String>[];
      await service.startListening(replies.add);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await service.stopListening();
      final sessions = elm.monitorSessions;
      expect(sessions, 3); // the probe attempts only
      expect(replies, isNotEmpty);
    });

    test('stays off for an adapter without monitor mode', () async {
      elm.rejectsMonitor = true;
      await connect();
      expect(service.canCaptureActive, isFalse);
      expect(elm.cra, isNull);
      expect(elm.caf, isTrue);
    });

    test('can be switched off before connecting', () async {
      service.canCaptureEnabled = false;
      await connect();
      expect(service.canCaptureActive, isFalse);
      expect(elm.monitorSessions, 0);
    });
  });
}
