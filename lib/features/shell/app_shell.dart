import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../drive/drive_page.dart';
import '../profiles/profile_form_page.dart';
import '../profiles/profiles_page.dart';
import '../trips/trips_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const ProfilesPage(),
      const DrivePage(),
      const TripsPage(),
    ];
    final titles = [
      AppStrings.profilesTab,
      AppStrings.driveTab,
      AppStrings.historyTab,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(titles[_index])),
      body: IndexedStack(
        index: _index,
        children: pages,
      ),
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              onPressed: () => showProfileFormSheet(context),
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.directions_car), label: 'Profiles'),
          NavigationDestination(icon: Icon(Icons.speed), label: 'Drive'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
        onDestinationSelected: (value) => setState(() => _index = value),
      ),
    );
  }
}
