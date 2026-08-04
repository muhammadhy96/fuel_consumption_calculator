import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Owns the fuel-flow series rendered by [FuelChartCard].
///
/// The drive screen refreshes its statistics roughly every 100 ms while the
/// chart only needs a new sample every 400 ms. Keeping the series here — and
/// letting [FuelChartCard] listen to it directly — means the chart rebuilds on
/// its own cadence instead of on every statistics `setState`.
class FuelChartController extends ChangeNotifier {
  /// Hard cap on retained samples. At one point per 400 ms this is ~160 s of
  /// history, comfortably more than the 60 s window that is ever displayed.
  static const int maxPoints = 400;

  /// Width of the visible time window, in seconds.
  static const double windowSeconds = 60;

  /// Number of leading points dropped per eviction, so trimming costs
  /// O(maxPoints / _evictBatch) element moves per [addPoint] on average.
  static const int _evictBatch = 64;

  final List<FlSpot> _points = <FlSpot>[];
  List<FlSpot> _visibleCache = const <FlSpot>[];
  bool _visibleDirty = true;
  double _latestValue = 0;

  /// True while no sample has been recorded.
  bool get isEmpty => _points.isEmpty;

  /// The most recently added value, in mL/s.
  double get latestValue => _latestValue;

  /// Left edge of the visible window, in seconds.
  double get viewStart {
    if (_points.isEmpty) return 0;
    final maxX = _points.last.x;
    return maxX > windowSeconds ? maxX - windowSeconds : 0.0;
  }

  /// Right edge of the visible window, in seconds.
  double get viewEnd => _points.isEmpty ? 0 : _points.last.x;

  /// The samples inside the last [windowSeconds].
  ///
  /// Recomputed only when the series actually changed — reading this getter
  /// repeatedly (as the chart does during layout) is free.
  List<FlSpot> get visiblePoints {
    if (_visibleDirty) {
      _visibleCache = _computeVisiblePoints();
      _visibleDirty = false;
    }
    return _visibleCache;
  }

  /// Appends a sample at [t] seconds with the given [value] in mL/s.
  void addPoint(double t, double value) {
    _points.add(FlSpot(t, value));
    if (_points.length > maxPoints) {
      _points.removeRange(0, _evictBatch);
    }
    _latestValue = value;
    _visibleDirty = true;
    notifyListeners();
  }

  /// Drops every sample, e.g. when a new trip starts.
  void clear() {
    _points.clear();
    _latestValue = 0;
    _visibleCache = const <FlSpot>[];
    _visibleDirty = false;
    notifyListeners();
  }

  List<FlSpot> _computeVisiblePoints() {
    if (_points.isEmpty) return const <FlSpot>[];
    final start = viewStart;
    // `x` is monotonically increasing, so the first in-window sample can be
    // found with a binary search instead of scanning the whole list.
    var lo = 0;
    var hi = _points.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_points[mid].x >= start) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    if (lo == 0) return List<FlSpot>.of(_points);
    return _points.sublist(lo);
  }
}

/// The `FUEL FLOW · LAST 60 s` card on the drive screen.
///
/// Rebuilds only when its [controller] notifies, which keeps the (relatively
/// expensive) [LineChart] layout off the drive screen's 100 ms refresh path.
class FuelChartCard extends StatefulWidget {
  const FuelChartCard({super.key, required this.controller});

  /// Source of the plotted series. Owned by the parent, not by this widget.
  final FuelChartController controller;

  @override
  State<FuelChartCard> createState() => _FuelChartCardState();
}

class _FuelChartCardState extends State<FuelChartCard> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant FuelChartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDarkElevated,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.surfaceDarkOutline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.show_chart,
                  color: AppTheme.accentCyan, size: 18),
              const SizedBox(width: 8),
              Text(
                'FUEL FLOW · LAST 60 s',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
              const Spacer(),
              Text(
                '${controller.latestValue.toStringAsFixed(2)} mL/s',
                style: const TextStyle(
                  color: AppTheme.accentCyan,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          RepaintBoundary(
            child: SizedBox(
              height: 220,
              child: LineChart(_buildFuelChart(controller)),
            ),
          ),
        ],
      ),
    );
  }

  LineChartData _buildFuelChart(FuelChartController controller) {
    if (controller.isEmpty) {
      return _chartDataFor(
        points: const [FlSpot(0, 0)],
        viewStart: 0,
        viewEnd: 1,
      );
    }
    final visiblePoints = controller.visiblePoints;
    final safePoints = visiblePoints.isEmpty
        ? const [FlSpot(0, 0)]
        : visiblePoints;
    return _chartDataFor(
      points: safePoints,
      viewStart: controller.viewStart,
      viewEnd: controller.viewEnd,
    );
  }

  LineChartData _chartDataFor({
    required List<FlSpot> points,
    required double viewStart,
    required double viewEnd,
  }) {
    final adjustedEnd = viewEnd == viewStart ? viewStart + 1 : viewEnd;

    return LineChartData(
      minX: viewStart,
      maxX: adjustedEnd,
      minY: 0,
      clipData: const FlClipData.all(),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: points,
          isCurved: true,
          curveSmoothness: 0.25,
          color: AppTheme.accentCyan,
          barWidth: 2.5,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppTheme.accentCyan.withValues(alpha: 0.35),
                AppTheme.accentCyan.withValues(alpha: 0.0),
              ],
            ),
          ),
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
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 10,
            reservedSize: 24,
            getTitlesWidget: (value, meta) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${value.toInt()}s',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 5,
            reservedSize: 32,
            getTitlesWidget: (value, meta) => Text(
              value.toStringAsFixed(0),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 10,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
