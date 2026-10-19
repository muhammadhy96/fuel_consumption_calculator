import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/formatters.dart';

/// Cost per km split by where it goes (`TripCost.perKmBreakdown`): one
/// stacked bar, and a legend with each part's amount per km.
class CostBreakdownBar extends StatelessWidget {
  const CostBreakdownBar({super.key, required this.items});

  final List<(String, double)> items;

  /// Keyed by label so a part keeps its colour whichever others are set.
  static const Map<String, Color> _colors = {
    'Fuel': AppTheme.accentCyan,
    'Depreciation': AppTheme.accentViolet,
    'Maintenance': AppTheme.accentAmber,
    'Insurance & tax': AppTheme.accentLime,
    'Other costs': Colors.white54,
    'Driver': AppTheme.accentMagenta,
  };

  @override
  Widget build(BuildContext context) {
    final shown = items.where((item) => item.$2 > 0).toList();
    final total = shown.fold<double>(0, (sum, item) => sum + item.$2);
    if (shown.isEmpty || !(total > 0)) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'COST PER KM',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final (label, perKm) in shown)
                  Expanded(
                    // At least 1 so a sliver of a part still shows.
                    flex: (perKm / total * 1000).round().clamp(1, 1000),
                    child: ColoredBox(color: _colorOf(label)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final (label, perKm) in shown)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _colorOf(label),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$label ',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    formatCostPerKm(perKm),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  static Color _colorOf(String label) => _colors[label] ?? Colors.white38;
}
