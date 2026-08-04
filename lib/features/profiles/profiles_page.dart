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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.car_rental_outlined,
                size: 72,
                color: Colors.white.withValues(alpha: 0.22),
              ),
              const SizedBox(height: 16),
              const Text(
                'No profiles yet',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Create a car profile to start tracking fuel.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => showProfileFormSheet(context),
                icon: const Icon(Icons.add),
                label: const Text('Create profile'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: profiles.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              '${profiles.length} PROFILE${profiles.length == 1 ? '' : 'S'}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontWeight: FontWeight.w700,
                fontSize: 11,
                letterSpacing: 1.4,
              ),
            ),
          );
        }
        final profile = profiles[index - 1];
        return ProfileCard(
          profile: profile,
          onEdit: () => showProfileFormSheet(context, profile: profile),
        );
      },
    );
  }
}

