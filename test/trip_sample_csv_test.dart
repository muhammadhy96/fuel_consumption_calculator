// Trip CSV layouts: the current 12-column one, and the legacy layouts that
// carried calculated engine load (PID 0104) at index 6.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fuel_consumption_calculator/core/services/file_service.dart';
import 'package:fuel_consumption_calculator/models/trip_sample.dart';

/// A real row from a 13-column log (Kia, 18 Oct 2026). Engine load, 54.5 %,
/// sits at index 6.
const List<dynamic> legacyRow13 = [
  8.35,
  1324.25,
  56.0,
  22.0,
  296.15,
  0.7729238224745525,
  54.509803921568626,
  0.0,
  1.0,
  5.46875,
  -5.46875,
  2,
  46.27450980392157,
];

/// The same sample in the current layout: engine load dropped.
const List<dynamic> currentRow12 = [
  8.35,
  1324.25,
  56.0,
  22.0,
  296.15,
  0.7729238224745525,
  0.0,
  1.0,
  5.46875,
  -5.46875,
  2,
  46.27450980392157,
];

const String legacyHeader13 =
    'Time (s),RPM,MAP (kPa),Speed (km/h),IAT (K),'
    'Fuel (mL/s),Engine Load (%),MAF (g/s),Eq Ratio,STFT (%),LTFT (%),'
    'Fuel System Status,Abs Load (%)';

const String legacyHeader12 =
    'Time (s),RPM,MAP (kPa),Speed (km/h),IAT (K),'
    'Fuel (mL/s),Engine Load (%),MAF (g/s),Eq Ratio,STFT (%),LTFT (%),'
    'Fuel System Status';

const String currentHeader12 =
    'Time (s),RPM,MAP (kPa),Speed (km/h),IAT (K),'
    'Fuel (mL/s),MAF (g/s),Eq Ratio,STFT (%),LTFT (%),Fuel System Status,'
    'Abs Load (%)';

void expectSameSample(TripSample actual, TripSample expected) {
  expect(actual.timeSeconds, expected.timeSeconds);
  expect(actual.rpm, expected.rpm);
  expect(actual.mapKpa, expected.mapKpa);
  expect(actual.speedKph, expected.speedKph);
  expect(actual.iatKelvin, expected.iatKelvin);
  expect(actual.fuelMlPerSec, expected.fuelMlPerSec);
  expect(actual.mafGramsPerSec, expected.mafGramsPerSec);
  expect(actual.equivRatio, expected.equivRatio);
  expect(actual.stftPercent, expected.stftPercent);
  expect(actual.ltftPercent, expected.ltftPercent);
  expect(actual.fuelSystemStatus, expected.fuelSystemStatus);
  expect(actual.absoluteLoadPercent, expected.absoluteLoadPercent);
}

void main() {
  group('TripSample.fromCsvRow', () {
    test('old 13-column and new 12-column rows decode to the same sample', () {
      final old = TripSample.fromCsvRow(legacyRow13);
      final current = TripSample.fromCsvRow(currentRow12);

      for (final s in [old, current]) {
        expect(s.rpm, 1324.25);
        expect(s.mapKpa, 56.0);
        expect(s.speedKph, 22.0);
        expect(s.fuelMlPerSec, 0.7729238224745525);
        expect(s.stftPercent, 5.46875);
        expect(s.ltftPercent, -5.46875);
        expect(s.absoluteLoadPercent, 46.27450980392157);
      }
      expectSameSample(old, current);
    });

    test('the header settles a 12-column row from before abs load', () {
      // Legacy 12 columns: engine load at 6, fuel status last, no abs load.
      const legacy12 = [
        8.35,
        1324.25,
        56.0,
        22.0,
        296.15,
        0.7729238224745525,
        54.509803921568626,
        0.0,
        1.0,
        5.46875,
        -5.46875,
        2,
      ];
      final s = TripSample.fromCsvRow(legacy12, hasEngineLoadColumn: true);
      expect(s.mafGramsPerSec, 0.0);
      expect(s.equivRatio, 1.0);
      expect(s.stftPercent, 5.46875);
      expect(s.ltftPercent, -5.46875);
      expect(s.fuelSystemStatus, 2);
      expect(s.absoluteLoadPercent, 0.0);
    });

    test('a header without engine load reads 12 columns as current', () {
      final s = TripSample.fromCsvRow(currentRow12, hasEngineLoadColumn: false);
      expectSameSample(s, TripSample.fromCsvRow(legacyRow13));
    });

    test('the oldest 6-column rows still parse', () {
      final s = TripSample.fromCsvRow(const [
        1.0,
        800.0,
        35.0,
        0.0,
        300.0,
        0.3,
      ]);
      expect(s.speedKph, 0.0);
      expect(s.iatKelvin, 300.0);
      expect(s.fuelMlPerSec, 0.3);
      expect(s.equivRatio, 1.0);
    });

    test('toCsvRow writes the current layout and reads back unchanged', () {
      final original = TripSample.fromCsvRow(legacyRow13);
      final row = original.toCsvRow();
      expect(row.length, TripSample.csvColumnCount);
      expectSameSample(TripSample.fromCsvRow(row), original);
    });
  });

  group('FileService.loadTripSamples', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('trip_csv_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<List<TripSample>> load(String header, List<dynamic> row) async {
      final file = File('${dir.path}/trip.csv')
        ..writeAsStringSync('$header\r\n${row.join(',')}\r\n');
      return FileService().loadTripSamples(file.path);
    }

    test('reads a legacy 13-column log', () async {
      final samples = await load(legacyHeader13, legacyRow13);
      expect(samples, hasLength(1));
      expectSameSample(samples.single, TripSample.fromCsvRow(currentRow12));
    });

    test('reads a current 12-column log', () async {
      final samples = await load(currentHeader12, currentRow12);
      expect(samples, hasLength(1));
      expectSameSample(samples.single, TripSample.fromCsvRow(legacyRow13));
    });

    test('reads a legacy 12-column log by its header', () async {
      final samples = await load(legacyHeader12, legacyRow13.take(12).toList());
      expect(samples.single.fuelSystemStatus, 2);
      expect(samples.single.absoluteLoadPercent, 0.0);
    });
  });
}
