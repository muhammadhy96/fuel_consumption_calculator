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
    return LineChart(
      LineChartData(
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
      ),
    );
  }
}
