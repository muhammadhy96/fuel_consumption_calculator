// Trip cost model, thesis eq. 3-34:
//   C_trip = V_f × P_fuel + S × k_m + T × k_t,   ω = V_f × P_fuel / C_trip
// plus the Hive tolerance of the profile and trip records that carry it.

import 'package:flutter_test/flutter_test.dart';

import 'package:fuel_consumption_calculator/core/utils/trip_cost.dart';
import 'package:fuel_consumption_calculator/models/car_profile.dart';
import 'package:fuel_consumption_calculator/models/non_fuel_costs.dart';
import 'package:fuel_consumption_calculator/models/trip.dart';

void main() {
  group('TripCost.compute', () {
    test('sums the three terms of eq. 3-34', () {
      // 5 L × 185 = 925, 60 km × 50 = 3000, 1.5 h × 1000 = 1500.
      final cost = TripCost.compute(
        fuelLiters: 5,
        distanceKm: 60,
        durationHours: 1.5,
        fuelPricePerLiter: 185,
        nonFuelCosts: const NonFuelCosts(other: 50),
        driverWagePerHour: 1000,
      )!;
      expect(cost.isFullModel, isTrue);
      expect(cost.fuelCost, 925);
      expect(cost.distanceCost, 3000);
      expect(cost.timeCost, 1500);
      expect(cost.total, 5425);
      expect(cost.costPerKm, closeTo(5425 / 60, 1e-9));
      expect(cost.fuelShare, closeTo(925 / 5425, 1e-12));
    });

    for (final (kM, kT) in [(0.0, 1000.0), (50.0, 0.0), (0.0, 0.0)]) {
      test('falls back to fuel cost alone when k_m=$kM, k_t=$kT', () {
        final cost = TripCost.compute(
          fuelLiters: 5,
          distanceKm: 60,
          durationHours: 1.5,
          fuelPricePerLiter: 185,
          nonFuelCosts: NonFuelCosts(other: kM),
          driverWagePerHour: kT,
        )!;
        expect(cost.isFullModel, isFalse);
        expect(cost.total, 925);
        expect(cost.costPerKm, closeTo(925 / 60, 1e-9));
        expect(cost.fuelShare, isNull);
      });
    }

    test('no fuel price means no cost at all', () {
      expect(
        TripCost.compute(
          fuelLiters: 5,
          distanceKm: 60,
          durationHours: 1.5,
          fuelPricePerLiter: 0,
          nonFuelCosts: const NonFuelCosts(other: 50),
          driverWagePerHour: 1000,
        ),
        isNull,
      );
    });

    test('cost per km is undefined before any distance', () {
      final cost = TripCost.compute(
        fuelLiters: 0.05,
        distanceKm: 0,
        durationHours: 0.01,
        fuelPricePerLiter: 185,
        nonFuelCosts: const NonFuelCosts(other: 50),
        driverWagePerHour: 1000,
      )!;
      expect(cost.costPerKm, isNull);
      expect(cost.perKmBreakdown, isEmpty);
      expect(cost.total, closeTo(0.05 * 185 + 0.01 * 1000, 1e-9));
    });

    test('the per-km breakdown names every part and sums to cost per km', () {
      // 5 L × 185 = 925 over 60 km, k_m = 20 + 15 + 10 + 5, 1.5 h × 1000.
      final cost = TripCost.compute(
        fuelLiters: 5,
        distanceKm: 60,
        durationHours: 1.5,
        fuelPricePerLiter: 185,
        nonFuelCosts: const NonFuelCosts(
          depreciation: 20,
          maintenance: 15,
          insurance: 10,
          other: 5,
        ),
        driverWagePerHour: 1000,
      )!;
      final breakdown = Map.fromEntries(
        cost.perKmBreakdown.map((e) => MapEntry(e.$1, e.$2)),
      );
      expect(breakdown.keys, [
        'Fuel',
        'Depreciation',
        'Maintenance',
        'Insurance & tax',
        'Other costs',
        'Driver',
      ]);
      expect(breakdown['Fuel'], closeTo(925 / 60, 1e-9));
      expect(breakdown['Depreciation'], 20);
      expect(breakdown['Driver'], closeTo(1500 / 60, 1e-9));
      expect(
        breakdown.values.reduce((a, b) => a + b),
        closeTo(cost.costPerKm!, 1e-9),
      );
    });

    test('without the full model the breakdown is fuel alone', () {
      final cost = TripCost.compute(
        fuelLiters: 5,
        distanceKm: 60,
        durationHours: 1.5,
        fuelPricePerLiter: 185,
        nonFuelCosts: const NonFuelCosts(depreciation: 20),
        driverWagePerHour: 0,
      )!;
      expect(cost.perKmBreakdown.map((e) => e.$1), ['Fuel']);
    });
  });

  group('CarProfile cost rates', () {
    test('a profile saved before the cost model loads with both at 0', () {
      final profile = CarProfile.fromMap({
        'id': 'profile-1791034794823',
        'name': 'Kia Rio',
        'fuelType': 'Petrol',
        'engineDisplacement': 1.4,
        'volumetricEfficiency': 85,
        'fuelPricePerLiter': 185,
        'notes': null,
        'createdAt': '2026-10-03T16:39:00.000',
      });
      expect(profile.nonFuelCostPerKm, 0);
      expect(profile.driverWagePerHour, 0);
      expect(profile.fuelPricePerLiter, 185);
    });

    test('a single k_m saved before the breakdown carries over as other', () {
      final profile = CarProfile.fromMap({
        'id': 'profile-1',
        'name': 'Kia Rio',
        'fuelType': 'Petrol',
        'fuelPricePerLiter': 185,
        'nonFuelCostPerKm': 50,
        'driverWagePerHour': 1000,
      });
      expect(profile.otherCostPerKm, 50);
      expect(profile.nonFuelCostPerKm, 50);
      // Saved again, it stays the same profile.
      expect(CarProfile.fromMap(profile.toMap()).nonFuelCostPerKm, 50);
    });

    test('derives k_m from price, resale, yearly costs and km per year', () {
      final profile = CarProfile(
        name: 'Ford',
        fuelType: 'Petrol',
        carPrice: 2000000,
        resaleValue: 800000,
        ownershipYears: 5,
        annualKm: 15000,
        maintenancePerYear: 150000,
        insurancePerYear: 60000,
        otherCostPerKm: 2,
      );
      final costs = profile.nonFuelCosts;
      // 1 200 000 lost over 75 000 km.
      expect(costs.depreciation, 16);
      expect(costs.maintenance, 10);
      expect(costs.insurance, 4);
      expect(costs.other, 2);
      expect(profile.nonFuelCostPerKm, 32);
    });

    test('a part with incomplete inputs counts as 0', () {
      final costs = CarProfile(
        name: 'Ford',
        fuelType: 'Petrol',
        carPrice: 2000000,
        maintenancePerYear: 150000,
      ).nonFuelCosts;
      expect(costs.depreciation, 0);
      expect(costs.maintenance, 0);
      expect(costs.total, 0);
    });

    test('round-trips through toMap and survives copyWith', () {
      final profile = CarProfile(
        name: 'Ford',
        fuelType: 'Petrol',
        fuelPricePerLiter: 185,
        carPrice: 2000000,
        resaleValue: 800000,
        ownershipYears: 5,
        annualKm: 15000,
        maintenancePerYear: 150000,
        insurancePerYear: 60000,
        otherCostPerKm: 20,
        driverWagePerHour: 1000,
      );
      final restored = CarProfile.fromMap(profile.toMap());
      expect(restored.nonFuelCostPerKm, 50);
      expect(restored.driverWagePerHour, 1000);

      final renamed = restored.copyWith(name: 'Ford Focus');
      expect(renamed.nonFuelCostPerKm, 50);
      expect(renamed.driverWagePerHour, 1000);
      expect(restored.copyWith(driverWagePerHour: 0).driverWagePerHour, 0);
    });
  });

  group('Trip cost fields', () {
    test('a trip saved before the cost model loads with no cost', () {
      final trip = Trip.fromMap({
        'id': 'trip-1',
        'profileId': 'profile-1',
        'startTime': '2026-10-18T08:31:27.623',
        'endTime': '2026-10-18T08:58:00.000',
        'durationSeconds': 1593,
        'totalFuelMl': 1200.0,
        'avgFuelMlPerSec': 0.75,
        'distanceKm': 12.0,
        'avgConsumptionLPer100Km': 10.0,
        'dataFilePath': null,
        'inProgress': false,
      });
      expect(trip.totalCost, isNull);
      expect(trip.costPerKm, isNull);
      expect(trip.fuelCostShare, isNull);
      expect(trip.costIsFullModel, isFalse);
      expect(trip.fuelPricePerLiter, 0);
      expect(trip.fuelCost, isNull);
      expect(trip.nonFuelCosts, isNull);
      expect(trip.obdDistanceKm, isNull);
    });

    test('round-trips through toMap', () {
      final trip = Trip(
        id: 'trip-2',
        profileId: 'profile-1',
        startTime: DateTime(2026, 10, 18, 8),
        endTime: DateTime(2026, 10, 18, 9),
        durationSeconds: 3600,
        totalFuelMl: 5000,
        avgFuelMlPerSec: 5000 / 3600,
        distanceKm: 60,
        obdDistanceKm: 62.5,
        fuelPricePerLiter: 185,
        nonFuelCostPerKm: 50,
        nonFuelCosts: const NonFuelCosts(depreciation: 30, maintenance: 20),
        driverWagePerHour: 1000,
        totalCost: 4925,
        costPerKm: 4925 / 60,
        fuelCostShare: 925 / 4925,
      );
      final restored = Trip.fromMap(trip.toMap());
      expect(restored.totalCost, 4925);
      expect(restored.costPerKm, 4925 / 60);
      expect(restored.fuelCostShare, 925 / 4925);
      expect(restored.nonFuelCostPerKm, 50);
      expect(restored.driverWagePerHour, 1000);
      expect(restored.costIsFullModel, isTrue);
      // 5 L at 185 per litre.
      expect(restored.fuelCost, 925);
      expect(restored.obdDistanceKm, 62.5);
      expect(restored.nonFuelCosts!.depreciation, 30);
      expect(restored.nonFuelCosts!.maintenance, 20);
      expect(
        restored.cost!.perKmBreakdown.map((e) => e.$1),
        ['Fuel', 'Depreciation', 'Maintenance', 'Driver'],
      );
    });

    test('an older trip breaks its single k_m down as other costs', () {
      final trip = Trip(
        id: 'trip-3',
        profileId: 'profile-1',
        startTime: DateTime(2026, 10, 18, 8),
        endTime: DateTime(2026, 10, 18, 9),
        durationSeconds: 3600,
        totalFuelMl: 5000,
        avgFuelMlPerSec: 5000 / 3600,
        distanceKm: 60,
        fuelPricePerLiter: 185,
        nonFuelCostPerKm: 50,
        driverWagePerHour: 1000,
        totalCost: 4925,
      );
      final cost = trip.cost!;
      expect(cost.total, closeTo(925 + 3000 + 1000, 1e-9));
      expect(
        cost.perKmBreakdown.map((e) => e.$1),
        ['Fuel', 'Other costs', 'Driver'],
      );
    });
  });
}
