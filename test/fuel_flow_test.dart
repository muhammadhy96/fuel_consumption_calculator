// Fuel-flow maths on the real [ObdService]. No connection is opened, so
// nothing here touches Bluetooth: `fuelFlow` is pure arithmetic and the few
// state getters exercised at the bottom never reach the transport.
//
// Two independent paths are covered.
//
// MAF path — the ECU already measured the air mass:
//   AFR      = 14.7 * equivalence ratio        (14.7 = stoichiometric petrol)
//   g/s fuel = g/s air / AFR
//   mL/s     = g/s fuel / 745 * 1000           (745 g/L petrol density)
//
// Speed-density path — no MAF sensor, so air mass is estimated from RPM, the
// manifold pressure and the intake air temperature via the ideal gas law:
//   IMAP     = RPM * MAP / (IAT * 2)           (/2 = one intake per 2 revs)
//   g/s air  = IMAP / 60 * VE/100 * displacement * 28.97 / 8.314
//                                              (28.97 g/mol air, R = 8.314)

import 'package:flutter_test/flutter_test.dart';

import 'package:fuel_consumption_calculator/core/services/obd_service.dart';
import 'package:fuel_consumption_calculator/core/services/storage_service.dart';

void main() {
  // Obd2Plugin grabs FlutterBluetoothSerial.instance in its field initialisers,
  // which installs a method-call handler and therefore needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ObdService service;

  setUp(() {
    service = ObdService(StorageService());
  });

  group('MAF path', () {
    test('14.7 g/s of air at stoichiometric burns 1 g/s of fuel', () {
      // AFR = 14.7 * 1.0 = 14.7
      // fuel = 14.7 / 14.7 = 1 g/s
      // mL/s = 1 / 745 * 1000 = 1.3422818791946...
      final value = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 14.7,
      );
      expect(value, closeTo(1.3422818791946307, 1e-9));
    });

    test('an idling MAF reading', () {
      // AFR = 14.7; fuel = 5.2 / 14.7 = 0.35374149659863946 g/s
      // mL/s = 0.35374149659863946 / 745 * 1000 = 0.474820800803542...
      final value = service.fuelFlow(
        800,
        30,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 5.2,
      );
      expect(value, closeTo(0.4748208008035429, 1e-9));
    });

    test('a rich commanded mixture (lambda 2.0) halves the fuel', () {
      // AFR = 14.7 * 2.0 = 29.4; fuel = 14.7 / 29.4 = 0.5 g/s
      // mL/s = 0.5 / 745 * 1000 = 0.6711409395973154
      final value = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        equivRatio: 2.0,
        mafGramsPerSec: 14.7,
      );
      expect(value, closeTo(0.6711409395973154, 1e-9));
    });

    test('MAP and IAT are ignored once MAF is supplied', () {
      // Nonsensical MAP / IAT (which would zero the speed-density estimate)
      // must not change the MAF answer.
      final withGarbage = service.fuelFlow(
        2000,
        0,
        0,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 14.7,
      );
      final withSaneAir = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 14.7,
      );
      expect(withGarbage, closeTo(1.3422818791946307, 1e-9));
      expect(withGarbage, withSaneAir);
    });

    test('displacement and VE are ignored once MAF is supplied', () {
      final small = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 40,
        engineDisplacementLiters: 1.0,
        mafGramsPerSec: 14.7,
      );
      final large = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 110,
        engineDisplacementLiters: 6.2,
        mafGramsPerSec: 14.7,
      );
      expect(small, large);
    });

    test('a zero MAF reading means zero fuel', () {
      expect(
        service.fuelFlow(
          2000,
          100,
          300,
          volumetricEfficiency: 85,
          engineDisplacementLiters: 2.0,
          mafGramsPerSec: 0,
        ),
        0,
      );
    });

    test('flow is linear in the MAF reading', () {
      final single = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 7.35,
      );
      final double_ = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 14.7,
      );
      expect(double_, closeTo(single * 2, 1e-12));
    });
  });

  group('speed-density path', () {
    test('2.0 L at 2000 rpm, 100 kPa, 300 K, VE 85 %', () {
      // IMAP = 2000 * 100 / (300 * 2) = 200000 / 600 = 333.3333...
      // air  = 333.3333/60 * 0.85 * 2.0 * 28.97 / 8.314
      //      = 5.555555 * 0.85 * 2.0 * 28.97 / 8.314 = 32.9090155828... g/s
      // fuel = 32.9090155828 / 14.7 = 2.238708543... g/s
      // mL/s = 2.238708543 / 745 * 1000 = 3.00497791013...
      final value = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
      );
      expect(value, closeTo(3.0049779101327494, 1e-9));
    });

    test('1.6 L idling: 800 rpm, 35 kPa, 30 degC (303.15 K), VE 85 %', () {
      // IMAP = 800 * 35 / (303.15 * 2) = 28000 / 606.3 = 46.18175...
      // air  = 46.18175/60 * 0.85 * 1.6 * 28.97 / 8.314 = 3.6475096... g/s
      // fuel = 3.6475096 / 14.7 = 0.2481298... g/s
      // mL/s = 0.2481298 / 745 * 1000 = 0.333060391820...
      final value = service.fuelFlow(
        800,
        35,
        303.15,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 1.6,
      );
      expect(value, closeTo(0.33306039182075003, 1e-9));
    });

    test('a lean commanded mixture (lambda 0.85) raises the fuel rate', () {
      // AFR = 14.7 * 0.85 = 12.495, so the same air mass carries more fuel:
      // 3.0049779101327494 / 0.85 = 3.5352681295679402
      final value = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        equivRatio: 0.85,
      );
      expect(value, closeTo(3.5352681295679402, 1e-9));
    });

    test('flow scales linearly with rpm, displacement and VE', () {
      double flow({
        double rpm = 2000,
        double ve = 85,
        double displacement = 2.0,
      }) =>
          service.fuelFlow(
            rpm,
            100,
            300,
            volumetricEfficiency: ve,
            engineDisplacementLiters: displacement,
          );

      final base = flow();
      expect(flow(rpm: 4000), closeTo(base * 2, 1e-9));
      expect(flow(displacement: 4.0), closeTo(base * 2, 1e-9));
      expect(flow(ve: 170), closeTo(base * 2, 1e-9));
    });

    test('flow scales inversely with intake air temperature', () {
      final cold = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
      );
      final hot = service.fuelFlow(
        2000,
        100,
        600,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
      );
      // Twice the absolute temperature = half the air density = half the fuel.
      expect(hot, closeTo(cold / 2, 1e-9));
    });

    test('a non-positive IAT yields zero rather than infinity', () {
      for (final iat in <double>[0, -1, -273.15]) {
        expect(
          service.fuelFlow(
            2000,
            100,
            iat,
            volumetricEfficiency: 85,
            engineDisplacementLiters: 2.0,
          ),
          0,
          reason: 'IAT $iat',
        );
      }
    });

    test('a non-positive MAP yields zero', () {
      for (final map in <double>[0, -5]) {
        expect(
          service.fuelFlow(
            2000,
            map,
            300,
            volumetricEfficiency: 85,
            engineDisplacementLiters: 2.0,
          ),
          0,
          reason: 'MAP $map',
        );
      }
    });

    test('zero VE or zero displacement yields zero', () {
      expect(
        service.fuelFlow(
          2000,
          100,
          300,
          volumetricEfficiency: 0,
          engineDisplacementLiters: 2.0,
        ),
        0,
      );
      expect(
        service.fuelFlow(
          2000,
          100,
          300,
          volumetricEfficiency: 85,
          engineDisplacementLiters: 0,
        ),
        0,
      );
    });
  });

  group('engine stopped', () {
    test('rpm 0 yields zero on the speed-density path', () {
      expect(
        service.fuelFlow(
          0,
          100,
          300,
          volumetricEfficiency: 85,
          engineDisplacementLiters: 2.0,
        ),
        0,
      );
    });

    test('rpm 0 yields zero even when the ECU still reports MAF', () {
      // The engine-off guard runs before the MAF branch, so a stale MAF reading
      // cannot keep the trip integrating fuel while the engine is stopped.
      expect(
        service.fuelFlow(
          0,
          100,
          300,
          volumetricEfficiency: 85,
          engineDisplacementLiters: 2.0,
          mafGramsPerSec: 14.7,
        ),
        0,
      );
    });

    test('a negative rpm reading yields zero', () {
      expect(
        service.fuelFlow(
          -1,
          100,
          300,
          volumetricEfficiency: 85,
          engineDisplacementLiters: 2.0,
          mafGramsPerSec: 14.7,
        ),
        0,
      );
    });
  });

  group('equivalence ratio handling', () {
    test('the default is stoichiometric', () {
      final explicit = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        equivRatio: 1.0,
      );
      final defaulted = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
      );
      expect(defaulted, explicit);
    });

    test('a zero or negative ratio falls back to stoichiometric', () {
      // PID 0144 reads 0 before the ECU has commanded anything; dividing by
      // that AFR would produce infinity.
      final stoich = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 14.7,
      );
      for (final ratio in <double>[0, -0.5]) {
        final value = service.fuelFlow(
          2000,
          100,
          300,
          volumetricEfficiency: 85,
          engineDisplacementLiters: 2.0,
          equivRatio: ratio,
          mafGramsPerSec: 14.7,
        );
        expect(value, stoich, reason: 'ratio $ratio');
        expect(value.isFinite, isTrue);
      }
    });

    test('fuel is inversely proportional to the ratio', () {
      double flow(double ratio) => service.fuelFlow(
            2000,
            100,
            300,
            volumetricEfficiency: 85,
            engineDisplacementLiters: 2.0,
            equivRatio: ratio,
            mafGramsPerSec: 14.7,
          );
      expect(flow(2.0), closeTo(flow(1.0) / 2, 1e-12));
      expect(flow(0.5), closeTo(flow(1.0) * 2, 1e-12));
    });
  });

  group('service state before a connection exists', () {
    test('nothing is connected and no PIDs are known', () {
      expect(service.isConnected, isFalse);
      expect(service.supportedPids, isEmpty);
      expect(service.activeProtocol, isNull);
      expect(service.lastCycleMillis, 0);
    });

    test('bulk mode is the starting mode', () {
      expect(service.bulkModeActive, isTrue);
    });

    test('the direct fuel-rate PID is off until it is enabled', () {
      expect(service.fuelRateSupported, isFalse);
      service.enableFuelRatePid();
      expect(service.fuelRateSupported, isTrue);
      // Idempotent: a second call must not disturb anything.
      service.enableFuelRatePid();
      expect(service.fuelRateSupported, isTrue);
    });

    test('requestSingleFrame gives up immediately when disconnected',
        () async {
      expect(await service.requestSingleFrame(), isNull);
    });
  });

  group('fuel type constants', () {

    test('diesel uses AFR 14.5 and 832 g/L', () {
      // fuel = 14.5 / 14.5 = 1 g/s; mL/s = 1 / 832 * 1000
      final value = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        fuelType: 'Diesel',
        mafGramsPerSec: 14.5,
      );
      expect(value, closeTo(1000 / 832, 1e-9));
    });

    test('lean diesel lambda reduces fuel proportionally', () {
      double flow(double lambda) => service.fuelFlow(
            1500,
            100,
            300,
            volumetricEfficiency: 85,
            engineDisplacementLiters: 2.0,
            fuelType: 'Diesel',
            equivRatio: lambda,
            mafGramsPerSec: 20,
          );
      expect(flow(3.0), closeTo(flow(1.0) / 3, 1e-12));
    });
  });

  group('overrun fuel cut-off detection', () {
    bool cut({
      double rpm = 2000,
      double speedKph = 60,
      bool isDiesel = false,
      double? throttle,
      double? closedThrottle,
      double? mapKpa,
      double? lambda,
      int? status,
    }) =>
        ObdService.isOverrunFuelCut(
          rpm: rpm,
          speedKph: speedKph,
          isDiesel: isDiesel,
          throttlePercent: throttle,
          closedThrottlePercent: closedThrottle,
          mapKpa: mapKpa,
          lambda: lambda,
          fuelSystemStatus: status,
        );

    test('closed throttle while moving above idle is a cut', () {
      expect(cut(throttle: 12.5, closedThrottle: 12.2), isTrue);
    });

    test('an open throttle is not a cut', () {
      expect(cut(throttle: 20, closedThrottle: 12.2), isFalse);
    });

    test('idle speed keeps fuelling', () {
      expect(cut(rpm: 900, throttle: 12.2, closedThrottle: 12.2), isFalse);
    });

    test('standing still is not a cut', () {
      expect(cut(speedKph: 0, throttle: 12.2, closedThrottle: 12.2), isFalse);
    });

    test('deep manifold vacuum above idle is a cut on petrol only', () {
      expect(cut(mapKpa: 25), isTrue);
      expect(cut(mapKpa: 45), isFalse);
      expect(cut(mapKpa: 25, isDiesel: true), isFalse);
    });

    test('without throttle or MAP nothing is assumed', () {
      expect(cut(), isFalse);
    });

    test('a commanded lambda of 0 is the ECU reporting the cut', () {
      expect(cut(rpm: 900, speedKph: 0, lambda: 0), isTrue);
      expect(cut(rpm: 0, lambda: 0), isFalse);
    });

    test('closed-loop status from PID 0103 overrides a closed throttle', () {
      expect(cut(throttle: 12.2, closedThrottle: 12.2, status: 0x02), isFalse);
      expect(cut(mapKpa: 25, status: 0x10), isFalse);
    });

    test('status 0x04 with a closed throttle is a confirmed cut', () {
      expect(cut(throttle: 12.3, closedThrottle: 12.2, status: 0x04), isTrue);
    });

    test('status 0x04 with an open throttle is power enrichment', () {
      expect(cut(throttle: 80, closedThrottle: 12.2, status: 0x04), isFalse);
      expect(cut(mapKpa: 95, status: 0x04), isFalse);
    });

    test('unrecognised status falls back to inference', () {
      expect(cut(throttle: 12.2, closedThrottle: 12.2, status: 0x01), isTrue);
    });
  });
  group('fuel trims', () {
    test('STFT + LTFT scale fuel mass by (1 + sum/100)', () {
      final value = service.fuelFlow(
        2000,
        100,
        300,
        volumetricEfficiency: 85,
        engineDisplacementLiters: 2.0,
        mafGramsPerSec: 14.7,
        stftPercent: 2,
        ltftPercent: 6,
      );
      expect(value, closeTo(1.3422818791946307 * 1.08, 1e-9));
    });

    test('combined trim is clamped and non-finite trims ignored', () {
      expect(ObdService.fuelTrimFactor(80, 40), 1.5);
      expect(ObdService.fuelTrimFactor(-100, 0), 0.5);
      expect(ObdService.fuelTrimFactor(double.nan, 5), closeTo(1.05, 1e-12));
    });
  });
}
