import 'package:flutter/material.dart';

import '../../core/services/obd_transport.dart';
import '../../core/theme/app_theme.dart';

class ConnectButton extends StatelessWidget {
  const ConnectButton({
    super.key,
    required this.connected,
    this.connectionType,
    required this.tripRunning,
    required this.onPressed,
  });

  final bool connected;

  /// Link of the connected adapter; the icon only shows a transport once one
  /// is actually in use.
  final ObdConnectionType? connectionType;
  final bool tripRunning;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppTheme.accentLime : AppTheme.accentAmber;
    final icon = !connected
        ? Icons.link
        : connectionType == ObdConnectionType.wifi
            ? Icons.wifi
            : Icons.bluetooth_connected;
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
          icon,
          color: tripRunning ? Colors.white24 : color,
        ),
      ),
    );
  }
}
