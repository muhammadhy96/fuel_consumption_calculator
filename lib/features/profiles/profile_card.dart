import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../models/car_profile.dart';
import '../../state/profile_provider.dart';
import '../../state/trip_provider.dart';
import '../../widgets/confirm_dialog.dart';

class ProfileCard extends StatelessWidget {
  const ProfileCard({super.key, required this.profile, required this.onEdit});

  final CarProfile profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final profiles = context.read<ProfileProvider>();
    final trips = context.watch<TripProvider>();
    final selected = profiles.selectedProfile?.id == profile.id;
    final tripCount = trips.tripsForProfile(profile.id).length;
    final subtitle =
        '${profile.fuelType} · ${profile.engineDisplacement != null ? '${profile.engineDisplacement!.toStringAsFixed(1)}L' : 'displacement N/A'}';

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => profiles.selectProfile(profile),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: AppTheme.surfaceDarkElevated,
          border: Border.all(
            color: selected
                ? AppTheme.accentCyan
                : AppTheme.surfaceDarkOutline,
            width: selected ? 1.4 : 1,
          ),
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppTheme.accentCyan.withValues(alpha: 0.13),
                    Colors.transparent,
                  ],
                )
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: selected
                      ? const [AppTheme.accentCyan, AppTheme.accentViolet]
                      : [Colors.white12, Colors.white10],
                ),
              ),
              child: Icon(
                selected ? Icons.check : Icons.directions_car,
                color: selected ? Colors.black : Colors.white60,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                  if (tripCount > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '$tripCount trip${tripCount == 1 ? '' : 's'} recorded',
                      style: const TextStyle(
                        color: AppTheme.accentCyan,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white54),
              color: AppTheme.surfaceDarkElevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.surfaceDarkOutline),
              ),
              onSelected: (value) async {
                if (value == 'edit') {
                  onEdit();
                } else if (value == 'delete') {
                  final blocked = trips.hasTrips(profile.id);
                  if (blocked) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content:
                          Text('Delete trips first before removing profile.'),
                    ));
                    return;
                  }
                  final confirmed = await showConfirmDialog(
                    context: context,
                    title: 'Delete profile',
                    message: 'Delete ${profile.name}?',
                  );
                  if (confirmed) {
                    await profiles.deleteProfile(profile.id);
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
