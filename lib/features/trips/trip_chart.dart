import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/trip_sample.dart';

/// Trip replay chart showing fuel flow (L/h) over the trip duration.
class TripChart extends StatelessWidget {
  const TripChart({super.key, required this.samples});

  final List<TripSample> samples;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return const Center(
        child: Text(
          'No samples recorded.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    final fuelSpots = <FlSpot>[
      for (final s in samples) FlSpot(s.timeSeconds, s.fuelMlPerSec * 3.6),
    ];

    final maxX = fuelSpots.last.x;
    final maxY = fuelSpots.fold<double>(0, (m, s) => s.y > m ? s.y : m);
    final yInterval = maxY / 5 > 0 ? maxY / 5 : 1.0;
    final axisStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.45),
      fontSize: 10,
    );

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX == 0 ? 1 : maxX,
        minY: 0,
        maxY: maxY == 0 ? 1 : maxY * 1.1,
        clipData: const FlClipData.all(),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: fuelSpots,
            isCurved: true,
            curveSmoothness: 0.2,
            color: AppTheme.accentCyan,
            barWidth: 2.4,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppTheme.accentCyan.withValues(alpha: 0.32),
                  AppTheme.accentCyan.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) => FlLine(
            color: Colors.white.withValues(alpha: 0.06),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: maxX / 5 > 1 ? maxX / 5 : 1,
              reservedSize: 28,
              getTitlesWidget: (value, meta) =>
                  Text('${value.toInt()}s', style: axisStyle),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameSize: 18,
            axisNameWidget: Text('Fuel flow (L/h)', style: axisStyle),
            sideTitles: SideTitles(
              showTitles: true,
              interval: yInterval,
              reservedSize: 34,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(maxY < 10 ? 1 : 0),
                style: axisStyle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

