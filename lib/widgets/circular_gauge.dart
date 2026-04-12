import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Radial gauge with a glowing arc, background track, tick marks and a
/// value-label stack. Animates smoothly between readings using an
/// [AnimatedBuilder] so high-frequency OBD updates don't jitter the needle.
class CircularGauge extends StatelessWidget {
  const CircularGauge({
    super.key,
    required this.value,
    required this.maxValue,
    required this.label,
    required this.unit,
    this.color = AppTheme.accentCyan,
    this.size = 220,
    this.secondary,
  });

  final double value;
  final double maxValue;
  final String label;
  final String unit;
  final Color color;
  final double size;

  /// Optional text shown beneath the numeric readout (e.g. a secondary stat).
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0, maxValue).toDouble();
    final fraction = maxValue <= 0 ? 0.0 : clamped / maxValue;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: fraction),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (context, animatedFraction, _) {
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _GaugePainter(
              fraction: animatedFraction,
              color: color,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 2,
                      color: Colors.white.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatValue(clamped),
                    style: TextStyle(
                      fontSize: size * 0.22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -1,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1,
                    ),
                  ),
                  if (secondary != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      secondary!,
                      style: TextStyle(
                        fontSize: 11,
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatValue(double v) {
    if (v >= 1000) return v.toStringAsFixed(0);
    if (v >= 100) return v.toStringAsFixed(0);
    if (v >= 10) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  // The arc spans 270° centred at the bottom, matching classic dial gauges.
  static const double _startAngle = math.pi * 0.75;
  static const double _sweepAngle = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final stroke = size.width * 0.08;
    final radius = (size.shortestSide / 2) - stroke;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Outer faint ring — gives the card depth.
    final outerPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, outerPaint);

    // Dim track for the full sweep.
    final trackPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.09)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, trackPaint);

    // Active arc with a soft gradient — brighter at the needle head.
    final arcPaint = Paint()
      ..shader = SweepGradient(
        startAngle: _startAngle,
        endAngle: _startAngle + _sweepAngle,
        colors: [
          color.withValues(alpha: 0.35),
          color,
        ],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect,
      _startAngle,
      _sweepAngle * fraction,
      false,
      arcPaint,
    );

    // Tick marks around the track so the dial reads like a real instrument.
    const tickCount = 30;
    final tickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 1.4;
    for (var i = 0; i <= tickCount; i++) {
      final t = i / tickCount;
      final angle = _startAngle + _sweepAngle * t;
      final isMajor = i % 5 == 0;
      final inner = radius - (isMajor ? stroke * 1.3 : stroke * 0.7);
      final outer = radius - stroke * 0.15;
      final p1 = Offset(
        center.dx + math.cos(angle) * inner,
        center.dy + math.sin(angle) * inner,
      );
      final p2 = Offset(
        center.dx + math.cos(angle) * outer,
        center.dy + math.sin(angle) * outer,
      );
      tickPaint.color =
          Colors.white.withValues(alpha: isMajor ? 0.3 : 0.12);
      canvas.drawLine(p1, p2, tickPaint);
    }

    // Glow dot at the tip of the active arc.
    final angle = _startAngle + _sweepAngle * fraction;
    final tip = Offset(
      center.dx + math.cos(angle) * radius,
      center.dy + math.sin(angle) * radius,
    );
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(tip, stroke * 0.55, glowPaint);
    canvas.drawCircle(tip, stroke * 0.35, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.color != color;
}
