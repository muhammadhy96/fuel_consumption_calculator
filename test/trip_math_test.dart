// Trip integration maths, exercised through the real [TripProvider].
//
// The provider's `_integrateFuelMl` / `_calculateDistanceKm` are private, so
// everything here goes through the public surface: startTrip -> addSample* ->
// stopTrip, and the returned [Trip] is asserted. Both collaborators are
// subclassed rather than mocked — `FileService` and `StorageService` are plain
// classes, so overriding the two methods the provider calls keeps the test off
// the disk and off Hive without weakening either production API.
//
// The integration is trapezoidal over consecutive samples:
//   fuel  (mL) += (f[i-1] + f[i]) / 2 * dt
//   dist  (km) += ((v[i-1] + v[i]) / 2 * dt) / 3600
// with any dt <= 0 skipped entirely.

import 'package:flutter_test/flutter_test.dart';

import 'package:fuel_consumption_calculator/core/services/file_service.dart';
import 'package:fuel_consumption_calculator/core/services/storage_service.dart';
import 'package:fuel_consumption_calculator/models/car_profile.dart';
import 'package:fuel_consumption_calculator/models/trip.dart';
import 'package:fuel_consumption_calculator/models/trip_sample.dart';
import 'package:fuel_consumption_calculator/state/trip_provider.dart';

/// Stands in for the on-disk CSV export.
///
/// [openTripWriter] returns null, which is exactly what the real service does
/// when the export directory cannot be opened, so every test here takes the
/// documented bulk-save fallback path.
class FakeFileService extends FileService {
  int openWriterCalls = 0;
  int bulkSaveCalls = 0;
  String? lastBulkProfileId;
  List<TripSample> lastBulkSamples = const [];
  bool bulkSaveThrows = false;
  String bulkSavePath = '/exports/FuelTrips/fake_trip.csv';

  @override
  Future<TripCsvWriter?> openTripWriter(String profileId) async {
    openWriterCalls += 1;
    return null;
  }

  @override
  Future<String> saveTripSamples(
    String profileId,
    List<TripSample> samples,
  ) async {
    bulkSaveCalls += 1;
    lastBulkProfileId = profileId;
    lastBulkSamples = samples;
    if (bulkSaveThrows) throw StateError('no space left on device');
    return bulkSavePath;
  }
}

/// In-memory stand-in for the Hive-backed store.
class FakeStorageService extends StorageService {
  final List<Trip> trips = [];
  bool saveThrows = false;

  @override
  Future<List<Trip>> loadTrips() async => List.of(trips);

  @override
  Future<void> saveTrip(Trip trip) async {
    if (saveThrows) throw StateError('box is closed');
    trips.add(trip);
  }

  @override
  Future<void> deleteTrip(String id) async {
    trips.removeWhere((trip) => trip.id == id);
  }
}

CarProfile buildProfile({String id = 'profile-1'}) => CarProfile(
      id: id,
      name: 'Test Car',
      fuelType: 'Petrol',
      engineDisplacement: 1.6,
    );

TripSample sample(
  double timeSeconds, {
  double fuelMlPerSec = 0,
  double speedKph = 0,
}) =>
    TripSample(
      timeSeconds: timeSeconds,
      rpm: 0,
      mapKpa: 0,
      speedKph: speedKph,
      iatKelvin: 293.15,
      fuelMlPerSec: fuelMlPerSec,
      engineLoadPercent: 0,
      mafGramsPerSec: 0,
      equivRatio: 1,
    );

void main() {
  late FakeFileService files;
  late FakeStorageService storage;
  late TripProvider provider;

  setUp(() {
    files = FakeFileService();
    storage = FakeStorageService();
    provider = TripProvider(files, storage);
  });

  tearDown(() {
    provider.dispose();
  });

  group('trapezoidal integration', () {
    test('fuel, distance and average consumption over a four-sample trip',
        () async {
      provider.startTrip(buildProfile());
      // t   fuel mL/s   speed km/h
      // 0       0            0
      // 1       2           36
      // 2       4           72
      // 3       4           72
      provider
        ..addSample(sample(0, fuelMlPerSec: 0, speedKph: 0))
        ..addSample(sample(1, fuelMlPerSec: 2, speedKph: 36))
        ..addSample(sample(2, fuelMlPerSec: 4, speedKph: 72))
        ..addSample(sample(3, fuelMlPerSec: 4, speedKph: 72));

      final trip = await provider.stopTrip();

      // fuel: (0+2)/2*1 + (2+4)/2*1 + (4+4)/2*1 = 1 + 3 + 4 = 8 mL
      expect(trip!.totalFuelMl, closeTo(8.0, 1e-12));
      // distance: (0+36)/2*1/3600 + (36+72)/2*1/3600 + (72+72)/2*1/3600
      //         = 18/3600 + 54/3600 + 72/3600 = 0.005 + 0.015 + 0.02 = 0.04 km
      expect(trip.distanceKm, closeTo(0.04, 1e-12));
      // duration comes from the last sample's timestamp: 3 s
      expect(trip.durationSeconds, 3);
      // average rate: 8 mL / 3 s
      expect(trip.avgFuelMlPerSec, closeTo(8 / 3, 1e-12));
      // consumption: (8 mL / 1000) / 0.04 km * 100 = 0.008/0.04*100 = 20
      expect(trip.avgConsumptionLPer100Km, closeTo(20.0, 1e-12));
    });

    test('uneven sample spacing is weighted by dt, not by sample count',
        () async {
      provider.startTrip(buildProfile());
      // A 0.4 s gap then a 4 s gap: the long segment must dominate.
      provider
        ..addSample(sample(0, fuelMlPerSec: 1, speedKph: 0))
        ..addSample(sample(0.4, fuelMlPerSec: 3, speedKph: 36))
        ..addSample(sample(4.4, fuelMlPerSec: 3, speedKph: 36));

      final trip = await provider.stopTrip();

      // fuel: (1+3)/2*0.4 + (3+3)/2*4 = 0.8 + 12 = 12.8 mL
      expect(trip!.totalFuelMl, closeTo(12.8, 1e-12));
      // distance: (0+36)/2*0.4/3600 + (36+36)/2*4/3600
      //         = 7.2/3600 + 144/3600 = 0.002 + 0.04 = 0.042 km
      expect(trip.distanceKm, closeTo(0.042, 1e-12));
      // duration: 4.4 s rounds to 4
      expect(trip.durationSeconds, 4);
      expect(trip.avgFuelMlPerSec, closeTo(12.8 / 4, 1e-12));
      // consumption: 0.0128 L / 0.042 km * 100 = 30.476190476...
      expect(
        trip.avgConsumptionLPer100Km,
        closeTo(30.476190476190474, 1e-9),
      );
    });

    test('duplicate timestamps (dt == 0) contribute nothing', () async {
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0, fuelMlPerSec: 10, speedKph: 100))
        ..addSample(sample(0, fuelMlPerSec: 20, speedKph: 200))
        ..addSample(sample(2, fuelMlPerSec: 20, speedKph: 200));

      final trip = await provider.stopTrip();

      // Only the 0 -> 2 s segment counts: (20+20)/2*2 = 40 mL
      expect(trip!.totalFuelMl, closeTo(40.0, 1e-12));
      // distance: (200+200)/2*2/3600 = 400/3600 = 0.11111... km
      expect(trip.distanceKm, closeTo(400 / 3600, 1e-12));
      expect(trip.durationSeconds, 2);
      // consumption: 0.04 L / (400/3600) km * 100 = 36 L/100km
      expect(trip.avgConsumptionLPer100Km, closeTo(36.0, 1e-9));
    });

    test('a sample that goes backwards in time is skipped, not subtracted',
        () async {
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0, fuelMlPerSec: 10, speedKph: 36))
        ..addSample(sample(1, fuelMlPerSec: 10, speedKph: 36))
        // Clock glitch: dt = -0.4 -> the whole segment is ignored.
        ..addSample(sample(0.6, fuelMlPerSec: 1000, speedKph: 1000));

      final trip = await provider.stopTrip();

      // fuel: (10+10)/2*1 = 10 mL only
      expect(trip!.totalFuelMl, closeTo(10.0, 1e-12));
      // distance: (36+36)/2*1/3600 = 0.01 km only
      expect(trip.distanceKm, closeTo(0.01, 1e-12));
    });

    test('a stationary trip burns fuel but covers no distance', () async {
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0, fuelMlPerSec: 0.5, speedKph: 0))
        ..addSample(sample(60, fuelMlPerSec: 0.5, speedKph: 0));

      final trip = await provider.stopTrip();

      // idle: (0.5+0.5)/2*60 = 30 mL
      expect(trip!.totalFuelMl, closeTo(30.0, 1e-12));
      expect(trip.distanceKm, 0);
      // distance == 0 must not produce Infinity or NaN
      expect(trip.avgConsumptionLPer100Km, 0);
      expect(trip.avgFuelMlPerSec, closeTo(0.5, 1e-12));
    });

    test('a single sample integrates to zero', () async {
      provider.startTrip(buildProfile());
      provider.addSample(sample(5, fuelMlPerSec: 42, speedKph: 90));

      final trip = await provider.stopTrip();

      expect(trip!.totalFuelMl, 0);
      expect(trip.distanceKm, 0);
      expect(trip.durationSeconds, 5);
      expect(trip.avgFuelMlPerSec, 0);
      expect(trip.avgConsumptionLPer100Km, 0);
    });

    test('a trip with no samples produces an all-zero summary', () async {
      provider.startTrip(buildProfile());

      final trip = await provider.stopTrip();

      expect(trip!.totalFuelMl, 0);
      expect(trip.distanceKm, 0);
      expect(trip.durationSeconds, 0);
      expect(trip.avgFuelMlPerSec, 0);
      expect(trip.avgConsumptionLPer100Km, 0);
    });

    test('duration rounds the final timestamp to the nearest second', () async {
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0))
        ..addSample(sample(12.7));

      final trip = await provider.stopTrip();

      expect(trip!.durationSeconds, 13);
    });
  });

  group('in-memory sample cap', () {
    test('evicted samples still count towards the trip totals', () async {
      // 52 000 samples at 1 Hz, 1 mL/s and 36 km/h throughout. The cap is
      // 50 000 with a 1 000-sample eviction batch, so this trims twice and the
      // trip summary has to come out identical to a full-buffer integration.
      const total = 52000;
      provider.startTrip(buildProfile());
      for (var i = 0; i < total; i++) {
        provider.addSample(
          sample(i.toDouble(), fuelMlPerSec: 1, speedKph: 36),
        );
      }

      expect(
        provider.samples.length,
        TripProvider.maxInMemorySamples,
        reason: 'the buffer should have been trimmed back to the cap',
      );

      final trip = await provider.stopTrip();

      // 51 999 one-second trapezoids of a constant 1 mL/s.
      expect(trip!.totalFuelMl, closeTo(51999.0, 1e-6));
      // 36 km/h for 51 999 s = 36 * 51999 / 3600 = 519.99 km
      expect(trip.distanceKm, closeTo(519.99, 1e-6));
      expect(trip.durationSeconds, 51999);
      expect(trip.avgFuelMlPerSec, closeTo(1.0, 1e-9));
      // 51.999 L over 519.99 km = 10 L/100km exactly.
      expect(trip.avgConsumptionLPer100Km, closeTo(10.0, 1e-9));
    });

    test('a trip that stays under the cap keeps every sample', () async {
      provider.startTrip(buildProfile());
      for (var i = 0; i < 1000; i++) {
        provider.addSample(sample(i.toDouble(), fuelMlPerSec: 1));
      }
      expect(provider.samples.length, 1000);
      await provider.stopTrip();
    });
  });

  group('CSV handoff', () {
    test('falls back to the bulk save when no streaming writer opened',
        () async {
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0, fuelMlPerSec: 1))
        ..addSample(sample(1, fuelMlPerSec: 1));

      final trip = await provider.stopTrip();

      expect(files.openWriterCalls, 1);
      expect(files.bulkSaveCalls, 1);
      expect(files.lastBulkProfileId, 'profile-1');
      expect(files.lastBulkSamples.length, 2);
      expect(trip!.dataFilePath, files.bulkSavePath);
    });

    test('a failing bulk save leaves the trip intact with no CSV path',
        () async {
      files.bulkSaveThrows = true;
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0, fuelMlPerSec: 2))
        ..addSample(sample(2, fuelMlPerSec: 2));

      final trip = await provider.stopTrip();

      expect(trip, isNotNull);
      expect(trip!.dataFilePath, isNull);
      expect(trip.totalFuelMl, closeTo(4.0, 1e-12)); // (2+2)/2*2
    });

    test('activeCsvPath is null while the streaming writer is unavailable', () {
      expect(provider.activeCsvPath, isNull);
      provider.startTrip(buildProfile());
      expect(provider.activeCsvPath, isNull);
    });
  });

  group('trip lifecycle', () {
    test('stopTrip returns null when no trip is running', () async {
      expect(await provider.stopTrip(), isNull);
      expect(files.bulkSaveCalls, 0);
    });

    test('addSample outside a running trip is ignored', () async {
      provider.addSample(sample(0, fuelMlPerSec: 99));
      expect(provider.samples, isEmpty);

      provider.startTrip(buildProfile());
      provider.addSample(sample(0, fuelMlPerSec: 1));
      await provider.stopTrip();
      // Samples are cleared on stop, and post-stop samples must not reopen it.
      provider.addSample(sample(1, fuelMlPerSec: 1));
      expect(provider.samples, isEmpty);
      expect(provider.running, isFalse);
    });

    test('a second startTrip while running does not reset the buffer', () {
      provider.startTrip(buildProfile());
      provider.addSample(sample(0, fuelMlPerSec: 1));
      provider.startTrip(buildProfile(id: 'profile-2'));
      expect(provider.samples.length, 1);
      expect(files.openWriterCalls, 1);
    });

    test('stopping records the trip against its profile', () async {
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0, fuelMlPerSec: 1, speedKph: 36))
        ..addSample(sample(10, fuelMlPerSec: 1, speedKph: 36));

      final trip = await provider.stopTrip();

      expect(provider.running, isFalse);
      expect(provider.elapsedSeconds, 0);
      expect(provider.samples, isEmpty);
      expect(provider.lastTrip, same(trip));
      expect(provider.hasTrips('profile-1'), isTrue);
      expect(provider.tripsForProfile('profile-1').single.id, trip!.id);
      expect(storage.trips.single.id, trip.id);
    });

    test('a storage failure does not lose the finished trip', () async {
      storage.saveThrows = true;
      provider.startTrip(buildProfile());
      provider
        ..addSample(sample(0, fuelMlPerSec: 1))
        ..addSample(sample(4, fuelMlPerSec: 3));

      final trip = await provider.stopTrip();

      expect(trip, isNotNull);
      // (1+3)/2*4 = 8 mL
      expect(trip!.totalFuelMl, closeTo(8.0, 1e-12));
      expect(provider.tripsForProfile('profile-1').single.id, trip.id);
      expect(storage.trips, isEmpty);
    });

    test('deleteTrip drops it from memory and from storage', () async {
      provider.startTrip(buildProfile());
      provider.addSample(sample(0, fuelMlPerSec: 1));
      final trip = await provider.stopTrip();

      await provider.deleteTrip('profile-1', trip!.id);

      expect(provider.tripsForProfile('profile-1'), isEmpty);
      expect(provider.hasTrips('profile-1'), isFalse);
      expect(storage.trips, isEmpty);
    });

    test('loadTrips groups by profile and sorts newest first', () async {
      final now = DateTime(2026, 8, 3, 12);
      storage.trips.addAll([
        Trip(
          id: 'old',
          profileId: 'profile-1',
          startTime: now.subtract(const Duration(hours: 2)),
          endTime: now.subtract(const Duration(hours: 1)),
          durationSeconds: 3600,
          totalFuelMl: 100,
          avgFuelMlPerSec: 1,
        ),
        Trip(
          id: 'new',
          profileId: 'profile-1',
          startTime: now,
          endTime: now.add(const Duration(minutes: 10)),
          durationSeconds: 600,
          totalFuelMl: 50,
          avgFuelMlPerSec: 2,
        ),
        Trip(
          id: 'other-profile',
          profileId: 'profile-2',
          startTime: now.subtract(const Duration(days: 1)),
          endTime: now.subtract(const Duration(days: 1)),
          durationSeconds: 1,
          totalFuelMl: 1,
          avgFuelMlPerSec: 1,
        ),
      ]);

      await provider.loadTrips();

      expect(
        provider.tripsForProfile('profile-1').map((t) => t.id),
        ['new', 'old'],
      );
      expect(provider.tripsForProfile('profile-2').single.id, 'other-profile');
      expect(provider.lastTrip?.id, 'new');
    });

    test('the exposed sample list cannot be mutated by callers', () {
      provider.startTrip(buildProfile());
      provider.addSample(sample(0, fuelMlPerSec: 1));
      expect(
        () => provider.samples.add(sample(1)),
        throwsUnsupportedError,
      );
    });
  });
}
