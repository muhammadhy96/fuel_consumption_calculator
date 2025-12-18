import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/car_profile.dart';
import '../../state/profile_provider.dart';

Future<void> showProfileFormSheet(BuildContext context, {CarProfile? profile}) async {
  final profiles = context.read<ProfileProvider>();
  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController(text: profile?.name ?? '');
  final displacementController =
      TextEditingController(text: profile?.engineDisplacement?.toString() ?? '');
  final veController =
      TextEditingController(text: (profile?.volumetricEfficiency ?? 85).toString());
  final notesController = TextEditingController(text: profile?.notes ?? '');
  final fuelTypes = ['Petrol', 'Diesel'];
  String fuelType = profile?.fuelType ?? fuelTypes.first;

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        left: 16,
        right: 16,
        top: 24,
      ),
      child: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                profile == null ? 'Create Profile' : 'Edit Profile',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Car name'),
                validator: (value) =>
                    value == null || value.isEmpty ? 'Name required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: fuelType,
                decoration: const InputDecoration(labelText: 'Fuel type'),
                items: fuelTypes
                    .map((ft) => DropdownMenuItem(value: ft, child: Text(ft)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) fuelType = value;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: displacementController,
                decoration:
                    const InputDecoration(labelText: 'Engine displacement (L)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: veController,
                decoration: const InputDecoration(
                  labelText: 'Volumetric efficiency (%)',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: notesController,
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: 2,
              ),
              const SizedBox(height: 20),
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
                            double.tryParse(displacementController.text);
                        final ve = double.tryParse(veController.text) ?? 85;
                        final notes = notesController.text.trim().isEmpty
                            ? null
                            : notesController.text.trim();
                        if (profile == null) {
                          await profiles.addProfile(CarProfile(
                            name: nameController.text.trim(),
                            fuelType: fuelType,
                            engineDisplacement: displacement,
                            volumetricEfficiency: ve,
                            notes: notes,
                          ));
                        } else {
                          await profiles.updateProfile(profile.copyWith(
                            name: nameController.text.trim(),
                            fuelType: fuelType,
                            engineDisplacement: displacement,
                            volumetricEfficiency: ve,
                            notes: notes,
                          ));
                        }
                        if (ctx.mounted) {
                          Navigator.of(ctx).pop();
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
