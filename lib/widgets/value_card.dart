import 'package:flutter/material.dart';

class ValueCard extends StatelessWidget {
  const ValueCard({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
    this.width,
  });

  final String label;
  final String value;
  final bool highlight;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final color = highlight ? Colors.teal : Colors.grey.shade200;
    return Container(
      width: width ?? (highlight ? double.infinity : 120),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment:
            highlight ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: highlight ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: highlight ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}
