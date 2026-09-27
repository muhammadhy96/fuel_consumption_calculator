import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../models/car_profile.dart';
import '../../state/profile_provider.dart';

/// Asks the driver to confirm which car this trip is being recorded for.
///
/// Returns the confirmed profile, or null when the driver backs out. The
/// caller is responsible for pushing the choice into [ProfileProvider] — the
/// sheet deliberately leaves the app's selection alone so backing out of the
/// OBD connect that follows does not silently switch cars.
///
/// Callers should only show this when a mix-up is actually possible — see
/// [shouldConfirmProfile].
Future<CarProfile?> showConfirmProfileSheet(BuildContext context) {
  return showModalBottomSheet<CarProfile>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Deliberately not dismissible by a stray tap: the whole point is that the
    // driver makes an explicit choice before anything is recorded.
    isDismissible: false,
    enableDrag: false,
    builder: (_) => const _ConfirmProfileSheet(),
  );
}

/// True when the driver has more than one car to choose between, so starting a
/// trip against the wrong one is possible.
bool shouldConfirmProfile(BuildContext context) =>
    context.read<ProfileProvider>().profiles.length > 1;

class _ConfirmProfileSheet extends StatefulWidget {
  const _ConfirmProfileSheet();

  @override
  State<_ConfirmProfileSheet> createState() => _ConfirmProfileSheetState();
}

class _ConfirmProfileSheetState extends State<_ConfirmProfileSheet> {
  CarProfile? _choice;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _choice = context.read<ProfileProvider>().selectedProfile;
  }

  void _confirm() {
    final choice = _choice;
    if (choice == null) return;
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ProfileProvider>().profiles;
    final choice = _choice;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDarkElevated,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.surfaceDarkOutline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_car, color: AppTheme.accentCyan),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Recording for which car?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Confirm the car before the trip starts — samples cannot be moved '
              'to another profile afterwards.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            if (_picking)
              _ProfileChoiceList(
                profiles: profiles,
                selectedId: choice?.id,
                onPick: (profile) => setState(() {
                  _choice = profile;
                  _picking = false;
                }),
              )
            else if (choice != null)
              _ActiveProfileCard(profile: choice)
            else
              const _EmptyChoiceNotice(),
            const SizedBox(height: 18),
            if (!_picking) ...[
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentCyan,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                onPressed: choice == null ? null : _confirm,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text(
                  'START WITH THIS CAR',
                  style: TextStyle(
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: profiles.length < 2
                          ? null
                          : () => setState(() => _picking = true),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('Change car'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.accentViolet,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white54,
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ] else
              TextButton(
                onPressed: () => setState(() => _picking = false),
                style: TextButton.styleFrom(foregroundColor: Colors.white54),
                child: const Text('Back'),
              ),
          ],
        ),
      ),
    );
  }
}

/// The car the trip is about to be recorded against, shown large enough that a
/// wrong one is hard to miss.
class _ActiveProfileCard extends StatelessWidget {
  const _ActiveProfileCard({required this.profile});

  final CarProfile profile;

  @override
  Widget build(BuildContext context) {
    final displacement = profile.displacementLabel;
    final price = profile.fuelPricePerLiter > 0
        ? '${profile.fuelPricePerLiter.toStringAsFixed(2)} / L'
        : 'no fuel price set';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.accentCyan, width: 1.4),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.accentCyan.withValues(alpha: 0.14),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [AppTheme.accentCyan, AppTheme.accentViolet],
              ),
            ),
            child: const Icon(Icons.directions_car, color: Colors.black),
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
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${profile.fuelType} · $displacement · $price',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline picker shown after "Change car".
class _ProfileChoiceList extends StatelessWidget {
  const _ProfileChoiceList({
    required this.profiles,
    required this.selectedId,
    required this.onPick,
  });

  final List<CarProfile> profiles;
  final String? selectedId;
  final ValueChanged<CarProfile> onPick;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.45,
      ),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: profiles.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, index) {
          final profile = profiles[index];
          final isSelected = profile.id == selectedId;
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onPick(profile),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.accentCyan
                      : AppTheme.surfaceDarkOutline,
                  width: isSelected ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isSelected ? AppTheme.accentCyan : Colors.white38,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          profile.fuelType,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyChoiceNotice extends StatelessWidget {
  const _EmptyChoiceNotice();

  @override
  Widget build(BuildContext context) {
    return Text(
      'No car profile is selected. Pick one in the Profiles tab first.',
      style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
    );
  }
}
