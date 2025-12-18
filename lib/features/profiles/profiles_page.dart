import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/profile_provider.dart';
import 'profile_card.dart';
import 'profile_form_page.dart';

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProfileProvider>();
    final profiles = state.profiles;

    if (profiles.isEmpty) {
      return const Center(child: Text('Create your first profile to begin.'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: profiles.length,
      itemBuilder: (_, index) {
        final profile = profiles[index];
        return ProfileCard(
          profile: profile,
          onEdit: () => showProfileFormSheet(context, profile: profile),
        );
      },
    );
  }
}
