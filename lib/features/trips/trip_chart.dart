import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/trip_sample.dart';

class TripChart extends StatelessWidget {
  const TripChart({super.key, required this.samples});

  final List<TripSample> samples;

  @override
  Widget build(BuildContext context) {
    final spots = samples
        .map((sample) => FlSpot(sample.timeSeconds, sample.fuelMlPerSec))
        .toList();
    if (spots.isEmpty) {
      return const Center(child: Text('No samples recorded.'));
    }
    final maxX = spots.last.x;
    final maxY = spots.fold<double>(0, (m, s) => s.y > m ? s.y : m);
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX == 0 ? 1 : maxX,
        minY: 0,
        maxY: maxY == 0 ? 1 : maxY * 1.1,
        clipData: const FlClipData.all(),
        borderData: FlBorderData(show: true),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Colors.teal,
            barWidth: 3,
            dotData: const FlDotData(show: false),
          ),
        ],
        gridData: const FlGridData(show: true),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            axisNameWidget: const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Time (s)'),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              interval: maxX / 5 > 1 ? maxX / 5 : 1,
              reservedSize: 32,
              getTitlesWidget: (value, meta) => Text(value.toInt().toString()),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Text('Fuel rate (mL/s)'),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              interval: maxY / 5 > 1 ? maxY / 5 : 1,
              reservedSize: 40,
              getTitlesWidget: (value, meta) =>
                  Text(value.toStringAsFixed(0)),
            ),
          ),
        ),
      ),
    );
  }
}
