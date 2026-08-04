import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class ConnectButton extends StatelessWidget {
  const ConnectButton({
    super.key,
    required this.connected,
    required this.tripRunning,
    required this.onPressed,
  });

  final bool connected;
  final bool tripRunning;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppTheme.accentLime : AppTheme.accentAmber;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        color: color.withValues(alpha: 0.08),
      ),
      child: IconButton(
        onPressed: tripRunning ? null : onPressed,
        tooltip: connected ? 'Reconnect' : 'Connect',
        icon: Icon(
          connected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
          color: tripRunning ? Colors.white24 : color,
        ),
      ),
    );
  }
}
