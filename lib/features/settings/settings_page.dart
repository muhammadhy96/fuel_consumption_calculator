import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../state/obd_provider.dart';
import '../../state/profile_provider.dart';
import '../../state/trip_provider.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: 'OBD DIAGNOSTICS',
            icon: Icons.bluetooth_connected,
            children: [const _ObdDiagnostics()],
          ),
          const SizedBox(height: 14),
          _Section(
            title: 'DATA',
            icon: Icons.storage,
            children: [const _DataSection()],
          ),
          const SizedBox(height: 14),
          _Section(
            title: 'ABOUT',
            icon: Icons.info_outline,
            children: [const _AboutSection()],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
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
              Icon(icon, size: 16, color: AppTheme.accentCyan),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _ObdDiagnostics extends StatelessWidget {
  const _ObdDiagnostics();

  @override
  Widget build(BuildContext context) {
    final obd = context.watch<ObdProvider>();
    final supported = obd.supportedPids;
    final cycleMillis = obd.lastCycleMillis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DiagRow(
          label: 'Connection',
          value: obd.connected ? 'Connected' : 'Disconnected',
          accent:
              obd.connected ? AppTheme.accentLime : AppTheme.accentMagenta,
        ),
        const SizedBox(height: 8),
        _DiagRow(
          label: 'Device',
          value: obd.device?.name ?? 'None',
        ),
        const SizedBox(height: 8),
        _DiagRow(
          label: 'Protocol',
          value: obd.activeProtocol ?? 'Unknown',
        ),
        const SizedBox(height: 8),
        _DiagRow(
          label: 'Request mode',
          value: obd.bulkModeActive ? 'Bulk (multi-PID)' : 'Single PID',
        ),
        const SizedBox(height: 8),
        _DiagRow(
          label: 'Cycle time',
          value: cycleMillis == 0 ? '--' : '$cycleMillis ms',
        ),
        const SizedBox(height: 8),
        _DiagRow(
          label: 'Frames decoded',
          value: obd.framesDecoded.toString(),
        ),
        const SizedBox(height: 8),
        _DiagRow(
          label: 'Direct fuel rate',
          value: obd.directFuelRateActive
              ? 'Supported (PID 015E)'
              : 'Not available',
        ),
        if (supported.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'SUPPORTED PIDs (${supported.length})',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final pid in supported.toList()..sort())
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.accentCyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    pid,
                    style: const TextStyle(
                      color: AppTheme.accentCyan,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow({
    required this.label,
    required this.value,
    this.accent = AppTheme.accentCyan,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        Text(
          value,
          style: TextStyle(
            color: accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _DataSection extends StatelessWidget {
  const _DataSection();

  @override
  Widget build(BuildContext context) {
    final profileCount =
        context.select<ProfileProvider, int>((p) => p.profiles.length);
    final selectedProfile =
        context.select<ProfileProvider, String?>((p) => p.selectedProfile?.id);
    final tripCount = selectedProfile != null
        ? context.select<TripProvider, int>(
            (t) => t.tripsForProfile(selectedProfile).length,
          )
        : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DiagRow(label: 'Profiles', value: profileCount.toString()),
        const SizedBox(height: 8),
        _DiagRow(label: 'Trips (selected)', value: tripCount.toString()),
        const SizedBox(height: 12),
        Text(
          'Trip data is stored locally in CSV format and can be found in the FuelTrips folder.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Fuel Trip Tracker',
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Real-time OBD-II fuel consumption calculator with '
          'bulk PID polling, live gauges and trip analytics.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'v1.0.0',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
