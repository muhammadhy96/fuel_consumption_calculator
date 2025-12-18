import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    final subtitle = '${profile.fuelType} • '
        '${profile.engineDisplacement != null ? '${profile.engineDisplacement!.toStringAsFixed(1)}L' : 'displacement N/A'}';
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Icon(selected ? Icons.check : Icons.directions_car),
        ),
        title: Text(profile.name),
        subtitle: Text(subtitle),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            if (value == 'edit') {
              onEdit();
            } else if (value == 'delete') {
              final blocked = trips.hasTrips(profile.id);
              if (blocked) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Delete trips first before removing profile.'),
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
        onTap: () => profiles.selectProfile(profile),
      ),
    );
  }
}
