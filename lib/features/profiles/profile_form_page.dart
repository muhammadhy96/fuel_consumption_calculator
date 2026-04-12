import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../models/car_profile.dart';
import '../../state/profile_provider.dart';

Future<void> showProfileFormSheet(
  BuildContext context, {
  CarProfile? profile,
}) async {
  final profiles = context.read<ProfileProvider>();
  final formKey = GlobalKey<FormState>();
  final nameCtrl = TextEditingController(text: profile?.name ?? '');
  final displacementCtrl = TextEditingController(
    text: profile?.engineDisplacement?.toString() ?? '',
  );
  final notesCtrl = TextEditingController(text: profile?.notes ?? '');
  final veCtrl = TextEditingController(
    text: profile?.volumetricEfficiency.toString() ?? '85',
  );
  final priceCtrl = TextEditingController(
    text: (profile?.fuelPricePerLiter ?? 0) > 0
        ? profile!.fuelPricePerLiter.toString()
        : '',
  );
  final fuelTypes = ['Petrol', 'Diesel', 'LPG', 'E85'];
  String fuelType = profile?.fuelType ?? fuelTypes.first;

  try {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceDarkElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          left: 20,
          right: 20,
          top: 16,
        ),
        child: Form(
          key: formKey,
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
                  profile == null ? 'Create Profile' : 'Edit Profile',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: nameCtrl,
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
                  value: fuelType,
                  decoration: const InputDecoration(
                    labelText: 'Fuel type',
                    prefixIcon: Icon(Icons.local_gas_station),
                  ),
                  dropdownColor: AppTheme.surfaceDarkElevated,
                  style: const TextStyle(color: Colors.white),
                  items: fuelTypes
                      .map((ft) => DropdownMenuItem(value: ft, child: Text(ft)))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) fuelType = value;
                  },
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: displacementCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Displacement (L)',
                          prefixIcon: Icon(Icons.settings),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: veCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Vol. Efficiency %',
                          prefixIcon: Icon(Icons.speed),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: priceCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Fuel price per liter',
                    prefixIcon: Icon(Icons.attach_money),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: notesCtrl,
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
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          if (!formKey.currentState!.validate()) return;
                          final displacement =
                              double.tryParse(displacementCtrl.text);
                          final ve = double.tryParse(veCtrl.text) ?? 85;
                          final price =
                              double.tryParse(priceCtrl.text) ?? 0;
                          final notes = notesCtrl.text.trim().isEmpty
                              ? null
                              : notesCtrl.text.trim();
                          if (profile == null) {
                            await profiles.addProfile(CarProfile(
                              name: nameCtrl.text.trim(),
                              fuelType: fuelType,
                              engineDisplacement: displacement,
                              volumetricEfficiency: ve,
                              fuelPricePerLiter: price,
                              notes: notes,
                            ));
                          } else {
                            await profiles.updateProfile(profile.copyWith(
                              name: nameCtrl.text.trim(),
                              fuelType: fuelType,
                              engineDisplacement: displacement,
                              volumetricEfficiency: ve,
                              fuelPricePerLiter: price,
                              notes: notes,
                            ));
                          }
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
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
      ),
    );
  } finally {
    nameCtrl.dispose();
    displacementCtrl.dispose();
    notesCtrl.dispose();
    veCtrl.dispose();
    priceCtrl.dispose();
  }
}
