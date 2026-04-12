import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../models/car_profile.dart';
import '../../state/obd_provider.dart';
import '../../state/trip_provider.dart';
import '../../widgets/circular_gauge.dart';
import '../../widgets/metric_tile.dart';
import '../../widgets/stat_pill.dart';

/// Full live telemetry screen: profile header, primary gauges, fuel-flow
/// callout, aux metric grid and trip stats. Uses [Selector] + targeted
/// [Consumer] widgets so each update from the OBD provider only rebuilds the
/// panels whose data actually changed.
class LiveDashboard extends StatelessWidget {
  const LiveDashboard({
    super.key,
    required this.profile,
    required this.fuelFlow,
    required this.tripStats,
  });

  final CarProfile profile;
  final double fuelFlow;
  final LiveTripStats tripStats;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProfileHeader(profile: profile, fuelFlow: fuelFlow),
        const SizedBox(height: 16),
        _GaugeRow(),
        const SizedBox(height: 14),
        _FuelFlowHero(fuelFlow: fuelFlow, tripStats: tripStats),
        const SizedBox(height: 14),
        _MetricGrid(),
        const SizedBox(height: 14),
        _TripStatsCard(tripStats: tripStats),
      ],
    );
  }
}

/// Aggregated running-trip metrics computed in `DrivePage`.
class LiveTripStats {
  const LiveTripStats({
    required this.totalFuelMl,
    required this.distanceKm,
    required this.avgConsumptionLPer100km,
    required this.instantConsumptionLPer100km,
    required this.costEstimate,
    required this.elapsedSeconds,
    required this.ecoScore,
  });

  final double totalFuelMl;
  final double distanceKm;
  final double avgConsumptionLPer100km;
  final double instantConsumptionLPer100km;
  final double costEstimate;
  final int elapsedSeconds;
  final int ecoScore;

  static const LiveTripStats zero = LiveTripStats(
    totalFuelMl: 0,
    distanceKm: 0,
    avgConsumptionLPer100km: 0,
    instantConsumptionLPer100km: 0,
    costEstimate: 0,
    elapsedSeconds: 0,
    ecoScore: 0,
  );
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.fuelFlow});

  final CarProfile profile;
  final double fuelFlow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.accentCyan.withValues(alpha: 0.14),
            AppTheme.accentViolet.withValues(alpha: 0.10),
            Colors.transparent,
          ],
        ),
        border: Border.all(color: AppTheme.surfaceDarkOutline),
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [AppTheme.accentCyan, AppTheme.accentViolet],
              ),
            ),
            child: const Icon(Icons.directions_car,
                color: Colors.black, size: 30),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${profile.fuelType} · '
                  '${profile.engineDisplacement != null ? '${profile.engineDisplacement!.toStringAsFixed(1)}L' : 'engine TBD'}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const _ConnectionBadge(),
        ],
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge();

  @override
  Widget build(BuildContext context) {
    return Selector<ObdProvider, (bool, bool)>(
      selector: (_, obd) => (obd.connected, obd.live),
      builder: (context, state, _) {
        final tripRunning = context.select<TripProvider, bool>((t) => t.running);
        final (connected, live) = state;
        final color = tripRunning
            ? AppTheme.accentLime
            : connected
                ? (live ? AppTheme.accentCyan : AppTheme.accentAmber)
                : AppTheme.accentMagenta;
        final label = tripRunning
            ? 'REC'
            : connected
                ? (live ? 'LIVE' : 'READY')
                : 'OFFLINE';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PulsingDot(color: color, pulse: live || tripRunning),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.pulse});
  final Color color;
  final bool pulse;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.pulse) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.5 + 0.5 * _ctrl.value),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.6 * _ctrl.value),
              blurRadius: 6 * _ctrl.value,
              spreadRadius: 1.5 * _ctrl.value,
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugeRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<ObdProvider, (double, double)>(
      selector: (_, obd) => (obd.rpm, obd.speedKph),
      builder: (context, state, _) {
        final (rpm, speed) = state;
        return LayoutBuilder(
          builder: (context, constraints) {
            final gaugeSize = ((constraints.maxWidth - 16) / 2)
                .clamp(140.0, 220.0);
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                CircularGauge(
                  value: rpm,
                  maxValue: 8000,
                  label: 'Engine',
                  unit: 'RPM',
                  size: gaugeSize,
                  color: AppTheme.accentCyan,
                  secondary: _rpmZone(rpm),
                ),
                CircularGauge(
                  value: speed,
                  maxValue: 240,
                  label: 'Speed',
                  unit: 'km/h',
                  size: gaugeSize,
                  color: AppTheme.accentLime,
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _rpmZone(double rpm) {
    if (rpm <= 0) return 'IDLE';
    if (rpm < 1500) return 'IDLE';
    if (rpm < 3000) return 'CRUISE';
    if (rpm < 5500) return 'POWER';
    return 'REDLINE';
  }
}

class _FuelFlowHero extends StatelessWidget {
  const _FuelFlowHero({required this.fuelFlow, required this.tripStats});

  final double fuelFlow;
  final LiveTripStats tripStats;

  @override
  Widget build(BuildContext context) {
    final lph = fuelFlow * 3.6;
    final calcMethod = context.select<ObdProvider, String>((obd) {
      if ((obd.fuelRateMlPerSecDirect ?? 0) > 0) return 'PID 015E';
      if (obd.mafGramsPerSec > 0) return 'MAF Sensor';
      if (obd.mapKpa > 0) return 'Speed-Density';
      return 'Estimating';
    });
    final isDirect = calcMethod == 'PID 015E';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.accentCyan, AppTheme.accentViolet],
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.accentCyan.withValues(alpha: 0.25),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_gas_station,
                  color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text(
                'FUEL FLOW',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: isDirect ? 0.3 : 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  calcMethod,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                fuelFlow.toStringAsFixed(fuelFlow >= 100 ? 0 : 2),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 56,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'mL/s',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${lph.toStringAsFixed(2)} L/h',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatPill(
                label: 'L/100km',
                value: _formatL100(tripStats.instantConsumptionLPer100km),
                icon: Icons.trending_down,
                accent: Colors.white,
              ),
              StatPill(
                label: 'Avg',
                value: _formatL100(tripStats.avgConsumptionLPer100km),
                icon: Icons.show_chart,
                accent: Colors.white,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatL100(double v) {
    if (v <= 0 || !v.isFinite) return '--';
    return v.toStringAsFixed(1);
  }
}

class _MetricGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 520 ? 4 : 3;
        return Selector<
            ObdProvider,
            ({
              double mapKpa,
              double mafGramsPerSec,
              double equivRatio,
              double iatKelvin,
              double coolantKelvin,
              double throttlePercent,
              double batteryVolts,
              double? engineLoadPercent,
              double? fuelTankPercent,
            })>(
          selector: (_, obd) => (
            mapKpa: obd.mapKpa,
            mafGramsPerSec: obd.mafGramsPerSec,
            equivRatio: obd.equivRatio,
            iatKelvin: obd.iatKelvin,
            coolantKelvin: obd.coolantKelvin,
            throttlePercent: obd.throttlePercent,
            batteryVolts: obd.batteryVolts,
            engineLoadPercent: obd.engineLoadPercent,
            fuelTankPercent: obd.fuelTankPercent,
          ),
          builder: (context, s, _) {
            final tiles = <Widget>[
              MetricTile(
                label: 'MAP',
                value: s.mapKpa > 0 ? s.mapKpa.toStringAsFixed(0) : '--',
                unit: 'kPa',
                icon: Icons.compress,
                accent: AppTheme.accentCyan,
              ),
              MetricTile(
                label: 'MAF',
                value: s.mafGramsPerSec > 0
                    ? s.mafGramsPerSec.toStringAsFixed(1)
                    : '--',
                unit: 'g/s',
                icon: Icons.air,
                accent: AppTheme.accentLime,
              ),
              MetricTile(
                label: 'Load',
                value: s.engineLoadPercent != null
                    ? s.engineLoadPercent!.toStringAsFixed(0)
                    : '--',
                unit: '%',
                icon: Icons.speed,
                accent: AppTheme.accentAmber,
              ),
              MetricTile(
                label: 'Intake',
                value: s.iatKelvin > 0
                    ? (s.iatKelvin - 273.15).toStringAsFixed(0)
                    : '--',
                unit: '°C',
                icon: Icons.thermostat,
                accent: AppTheme.accentMagenta,
              ),
              MetricTile(
                label: 'Coolant',
                value: s.coolantKelvin > 0
                    ? (s.coolantKelvin - 273.15).toStringAsFixed(0)
                    : '--',
                unit: '°C',
                icon: Icons.water_drop,
                accent: AppTheme.accentViolet,
              ),
              MetricTile(
                label: 'Throttle',
                value: s.throttlePercent > 0
                    ? s.throttlePercent.toStringAsFixed(0)
                    : '--',
                unit: '%',
                icon: Icons.tune,
                accent: AppTheme.accentCyan,
              ),
              MetricTile(
                label: 'Battery',
                value: s.batteryVolts > 0
                    ? s.batteryVolts.toStringAsFixed(1)
                    : '--',
                unit: 'V',
                icon: Icons.battery_charging_full,
                accent: AppTheme.accentLime,
              ),
              MetricTile(
                label: 'λ',
                value: s.equivRatio > 0
                    ? s.equivRatio.toStringAsFixed(2)
                    : '--',
                icon: Icons.science,
                accent: AppTheme.accentAmber,
              ),
              if (s.fuelTankPercent != null)
                MetricTile(
                  label: 'Tank',
                  value: s.fuelTankPercent!.toStringAsFixed(0),
                  unit: '%',
                  icon: Icons.propane_tank,
                  accent: AppTheme.accentMagenta,
                ),
            ];
            return GridView.count(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.25,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: tiles,
            );
          },
        );
      },
    );
  }
}

class _TripStatsCard extends StatelessWidget {
  const _TripStatsCard({required this.tripStats});
  final LiveTripStats tripStats;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDarkElevated,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.surfaceDarkOutline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.route, color: AppTheme.accentCyan, size: 16),
              const SizedBox(width: 8),
              Text(
                'TRIP IN PROGRESS',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              if (tripStats.ecoScore > 0)
                _EcoScoreBadge(score: tripStats.ecoScore),
              const SizedBox(width: 10),
              Text(
                formatDuration(tripStats.elapsedSeconds),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _TripStatCell(
                  label: 'Distance',
                  value: tripStats.distanceKm.toStringAsFixed(2),
                  unit: 'km',
                ),
              ),
              Expanded(
                child: _TripStatCell(
                  label: 'Fuel used',
                  value: (tripStats.totalFuelMl / 1000).toStringAsFixed(3),
                  unit: 'L',
                ),
              ),
              Expanded(
                child: _TripStatCell(
                  label: 'Est. cost',
                  value: tripStats.costEstimate > 0
                      ? tripStats.costEstimate.toStringAsFixed(2)
                      : '--',
                  unit: '€',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TripStatCell extends StatelessWidget {
  const _TripStatCell({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Colors.white.withValues(alpha: 0.55),
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              unit,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _EcoScoreBadge extends StatelessWidget {
  const _EcoScoreBadge({required this.score});
  final int score;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    if (score >= 80) {
      color = AppTheme.accentLime;
      label = 'ECO';
    } else if (score >= 50) {
      color = AppTheme.accentAmber;
      label = 'OK';
    } else {
      color = AppTheme.accentMagenta;
      label = 'HIGH';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.eco, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '$score',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.7),
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}
