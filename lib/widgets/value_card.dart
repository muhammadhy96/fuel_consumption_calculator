import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

class ValueCard extends StatelessWidget {
  const ValueCard({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
    this.width,
    this.icon,
  });

  final String label;
  final String value;
  final bool highlight;
  final double? width;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? (highlight ? double.infinity : 120),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: highlight
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.accentCyan, AppTheme.accentViolet],
              )
            : null,
        color: highlight ? null : AppTheme.surfaceDarkElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight
              ? Colors.transparent
              : AppTheme.surfaceDarkOutline,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            highlight ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: highlight
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: highlight ? Colors.white : Colors.white54,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                  color: highlight
                      ? Colors.white.withValues(alpha: 0.85)
                      : Colors.white54,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: highlight ? Alignment.center : Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: highlight ? 32 : 20,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
