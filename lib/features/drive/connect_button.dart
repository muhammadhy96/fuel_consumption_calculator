import 'package:flutter/material.dart';

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
    return TextButton.icon(
      onPressed: tripRunning ? null : onPressed,
      icon: const Icon(Icons.bluetooth),
      label: Text(connected ? 'Reconnect' : 'Connect'),
    );
  }
}
