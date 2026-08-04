import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../models/car_profile.dart';
import '../../state/profile_provider.dart';

Future<void> showProfileFormSheet(
  BuildContext context, {
  CarProfile? profile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surfaceDarkElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ProfileFormSheet(profile: profile),
  );
}

/// Body of the create/edit sheet.
///
/// This is a [StatefulWidget] specifically so the [TextEditingController]s are
/// owned by an element in the sheet's own route. Creating them beside
/// `showModalBottomSheet` and disposing them after its future completes is
/// unsafe: that future resolves the moment `Navigator.pop` is called, while the
/// sheet is still animating out and its fields are still mounted and
/// rebuilding — so the next `didUpdateWidget` re-subscribes to a controller
/// that has already been disposed.
class _ProfileFormSheet extends StatefulWidget {
  const _ProfileFormSheet({this.profile});

  final CarProfile? profile;

  @override
  State<_ProfileFormSheet> createState() => _ProfileFormSheetState();
}

class _ProfileFormSheetState extends State<_ProfileFormSheet> {
  static const List<String> _fuelTypes = ['Petrol', 'Diesel', 'LPG', 'E85'];

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _displacementCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _veCtrl;
  late final TextEditingController _priceCtrl;
  late String _fuelType;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _nameCtrl = TextEditingController(text: profile?.name ?? '');
    _displacementCtrl = TextEditingController(
      text: profile?.engineDisplacement?.toString() ?? '',
    );
    _notesCtrl = TextEditingController(text: profile?.notes ?? '');
    _veCtrl = TextEditingController(
      text: profile?.volumetricEfficiency.toString() ?? '85',
    );
    _priceCtrl = TextEditingController(
      text: (profile?.fuelPricePerLiter ?? 0) > 0
          ? profile!.fuelPricePerLiter.toString()
          : '',
    );
    _fuelType = profile?.fuelType ?? _fuelTypes.first;
  }

  @override
  void dispose() {
    // Runs when the route is genuinely removed, after the exit transition.
    _nameCtrl.dispose();
    _displacementCtrl.dispose();
    _notesCtrl.dispose();
    _veCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final displacement = double.tryParse(_displacementCtrl.text);
    final ve = double.tryParse(_veCtrl.text) ?? 85;
    final price = double.tryParse(_priceCtrl.text) ?? 0;
    final notes =
        _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim();
    // Resolved before the await so no BuildContext is used across the gap.
    final profiles = context.read<ProfileProvider>();
    final navigator = Navigator.of(context);
    final existing = widget.profile;

    if (existing == null) {
      await profiles.addProfile(CarProfile(
        name: _nameCtrl.text.trim(),
        fuelType: _fuelType,
        engineDisplacement: displacement,
        volumetricEfficiency: ve,
        fuelPricePerLiter: price,
        notes: notes,
      ));
    } else {
      await profiles.updateProfile(existing.copyWith(
        name: _nameCtrl.text.trim(),
        fuelType: _fuelType,
        engineDisplacement: displacement,
        volumetricEfficiency: ve,
        fuelPricePerLiter: price,
        notes: notes,
      ));
    }
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        left: 20,
        right: 20,
        top: 16,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                widget.profile == null ? 'Create Profile' : 'Edit Profile',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Car name',
                  prefixIcon: Icon(Icons.directions_car),
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Name required' : null,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _fuelType,
                decoration: const InputDecoration(
                  labelText: 'Fuel type',
                  prefixIcon: Icon(Icons.local_gas_station),
                ),
                dropdownColor: AppTheme.surfaceDarkElevated,
                style: const TextStyle(color: Colors.white),
                items: _fuelTypes
                    .map((ft) => DropdownMenuItem(value: ft, child: Text(ft)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) _fuelType = value;
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _displacementCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Displacement (L)',
                        prefixIcon: Icon(Icons.settings),
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _veCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Vol. Efficiency %',
                        prefixIcon: Icon(Icons.speed),
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _priceCtrl,
                decoration: const InputDecoration(
                  labelText: 'Fuel price per liter',
                  prefixIcon: Icon(Icons.attach_money),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _notesCtrl,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  prefixIcon: Icon(Icons.notes),
                ),
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _save,
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
