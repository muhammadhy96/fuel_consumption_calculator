import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../drive/drive_page.dart';
import '../profiles/profile_form_page.dart';
import '../profiles/profiles_page.dart';
import '../settings/settings_page.dart';
import '../trips/trips_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 1;

  static const _pages = <Widget>[
    ProfilesPage(),
    DrivePage(),
    TripsPage(),
    SettingsPage(),
  ];

  static const _titles = <String>[
    AppStrings.profilesTab,
    AppStrings.driveTab,
    AppStrings.historyTab,
    'Settings',
  ];

  static const _icons = <IconData>[
    Icons.directions_car_outlined,
    Icons.speed_outlined,
    Icons.history_outlined,
    Icons.tune_outlined,
  ];

  static const _iconsFilled = <IconData>[
    Icons.directions_car,
    Icons.speed,
    Icons.history,
    Icons.tune,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: false,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(
                  colors: [AppTheme.accentCyan, AppTheme.accentViolet],
                ),
              ),
              child: const Icon(Icons.local_gas_station,
                  color: Colors.black, size: 18),
            ),
            const SizedBox(width: 10),
            Text(_titles[_index]),
          ],
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: _pages,
      ),
      floatingActionButton: _index == 0
          ? FloatingActionButton.extended(
              onPressed: () => showProfileFormSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('New profile'),
            )
          : null,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: AppTheme.surfaceDarkOutline, width: 1),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          destinations: [
            for (var i = 0; i < _titles.length; i++)
              NavigationDestination(
                icon: Icon(_icons[i]),
                selectedIcon: Icon(_iconsFilled[i]),
                label: _titles[i],
              ),
          ],
          onDestinationSelected: (value) => setState(() => _index = value),
        ),
      ),
    );
  }
}
