import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/trip_sample.dart';

/// Trip replay chart showing fuel flow (primary), RPM/100 (secondary), and
/// speed/10 (tertiary) over the trip duration.
class TripChart extends StatefulWidget {
  const TripChart({super.key, required this.samples});

  final List<TripSample> samples;

  @override
  State<TripChart> createState() => _TripChartState();
}

class _TripChartState extends State<TripChart> {
  bool _showRpm = true;
  bool _showSpeed = true;

  @override
  Widget build(BuildContext context) {
    if (widget.samples.isEmpty) {
      return const Center(
        child: Text(
          'No samples recorded.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    final fuelSpots = <FlSpot>[];
    final rpmSpots = <FlSpot>[];
    final speedSpots = <FlSpot>[];
    for (final s in widget.samples) {
      fuelSpots.add(FlSpot(s.timeSeconds, s.fuelMlPerSec));
      rpmSpots.add(FlSpot(s.timeSeconds, s.rpm / 100));
      speedSpots.add(FlSpot(s.timeSeconds, s.speedKph / 10));
    }

    final maxX = fuelSpots.last.x;
    final maxY = fuelSpots.fold<double>(0, (m, s) => s.y > m ? s.y : m);

    return Column(
      children: [
        Row(
          children: [
            _ChipToggle(
              label: 'Fuel',
              color: AppTheme.accentCyan,
              active: true,
              onTap: null,
            ),
            const SizedBox(width: 6),
            _ChipToggle(
              label: 'RPM',
              color: AppTheme.accentAmber,
              active: _showRpm,
              onTap: () => setState(() => _showRpm = !_showRpm),
            ),
            const SizedBox(width: 6),
            _ChipToggle(
              label: 'Speed',
              color: AppTheme.accentLime,
              active: _showSpeed,
              onTap: () => setState(() => _showSpeed = !_showSpeed),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: LineChart(
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
                if (_showRpm)
                  LineChartBarData(
                    spots: rpmSpots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    color: AppTheme.accentAmber.withValues(alpha: 0.45),
                    barWidth: 1.2,
                    dotData: const FlDotData(show: false),
                  ),
                if (_showSpeed)
                  LineChartBarData(
                    spots: speedSpots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    color: AppTheme.accentLime.withValues(alpha: 0.4),
                    barWidth: 1.2,
                    dotData: const FlDotData(show: false),
                  ),
              ],
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: Colors.white.withValues(alpha: 0.06),
                  strokeWidth: 1,
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: maxX / 5 > 1 ? maxX / 5 : 1,
                    reservedSize: 28,
                    getTitlesWidget: (value, meta) => Text(
                      '${value.toInt()}s',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: maxY / 5 > 1 ? maxY / 5 : 1,
                    reservedSize: 34,
                    getTitlesWidget: (value, meta) => Text(
                      value.toStringAsFixed(0),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChipToggle extends StatelessWidget {
  const _ChipToggle({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? color : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: active ? color : Colors.white24,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: active ? color : Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
