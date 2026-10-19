import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
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
  static const List<String> _fuelTypes = ['Petrol', 'Diesel'];

  static final List<TextInputFormatter> _decimalInput = [
    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
  ];

  /// Accepts `1.6` and `1,6` (comma-decimal keyboards). Null when the text is
  /// empty or not a finite number.
  static double? _parseNumber(String? text) {
    final normalized = (text ?? '').trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    final value = double.tryParse(normalized);
    return value != null && value.isFinite ? value : null;
  }

  static String? _validateDisplacement(String? text) {
    if ((text ?? '').trim().isEmpty) return 'Displacement required';
    final value = _parseNumber(text);
    if (value == null) return 'Enter a number, e.g. 1.6';
    if (value > 100) return 'Enter litres, not cc (e.g. 1.6)';
    if (value < 0.5 || value > 10) return 'Between 0.5 and 10 L';
    return null;
  }

  static String? _validatePrice(String? text) {
    if ((text ?? '').trim().isEmpty) return null;
    final value = _parseNumber(text);
    if (value == null || value < 0) return 'Enter a price, e.g. 1.85';
    return null;
  }

  /// k_m and k_t of the trip cost model: optional, but never negative.
  static String? _validateRate(String? text) {
    if ((text ?? '').trim().isEmpty) return null;
    final value = _parseNumber(text);
    if (value == null || value < 0) return 'Enter 0 or more';
    return null;
  }

  /// Blank for an unset (0) rate, so the hint shows instead of `0.0`.
  static String _rateText(double? value) =>
      (value ?? 0) > 0 ? value.toString() : '';

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _displacementCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _carPriceCtrl;
  late final TextEditingController _resaleCtrl;
  late final TextEditingController _yearsCtrl;
  late final TextEditingController _annualKmCtrl;
  late final TextEditingController _maintenanceCtrl;
  late final TextEditingController _insuranceCtrl;
  late final TextEditingController _otherCostCtrl;
  late final TextEditingController _wageCtrl;

  /// The k_m inputs, so the per-km preview follows every keystroke.
  late final Listenable _costInputs = Listenable.merge([
    _carPriceCtrl,
    _resaleCtrl,
    _yearsCtrl,
    _annualKmCtrl,
    _maintenanceCtrl,
    _insuranceCtrl,
    _otherCostCtrl,
  ]);
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
    _priceCtrl = TextEditingController(
      text: _rateText(profile?.fuelPricePerLiter),
    );
    _carPriceCtrl = TextEditingController(text: _rateText(profile?.carPrice));
    _resaleCtrl = TextEditingController(text: _rateText(profile?.resaleValue));
    _yearsCtrl =
        TextEditingController(text: _rateText(profile?.ownershipYears));
    _annualKmCtrl = TextEditingController(text: _rateText(profile?.annualKm));
    _maintenanceCtrl =
        TextEditingController(text: _rateText(profile?.maintenancePerYear));
    _insuranceCtrl =
        TextEditingController(text: _rateText(profile?.insurancePerYear));
    _otherCostCtrl =
        TextEditingController(text: _rateText(profile?.otherCostPerKm));
    _wageCtrl = TextEditingController(
      text: _rateText(profile?.driverWagePerHour),
    );
    final savedFuelType = profile?.fuelType;
    _fuelType = _fuelTypes.contains(savedFuelType)
        ? savedFuelType!
        : _fuelTypes.first;
  }

  @override
  void dispose() {
    // Runs when the route is genuinely removed, after the exit transition.
    _nameCtrl.dispose();
    _displacementCtrl.dispose();
    _notesCtrl.dispose();
    _priceCtrl.dispose();
    _carPriceCtrl.dispose();
    _resaleCtrl.dispose();
    _yearsCtrl.dispose();
    _annualKmCtrl.dispose();
    _maintenanceCtrl.dispose();
    _insuranceCtrl.dispose();
    _otherCostCtrl.dispose();
    _wageCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // Displacement passed validation, so it parses.
    final displacement = _parseNumber(_displacementCtrl.text)!;
    final price = _parseNumber(_priceCtrl.text) ?? 0;
    final costs = _costProfile();
    final wage = _parseNumber(_wageCtrl.text) ?? 0;
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
        fuelPricePerLiter: price,
        carPrice: costs.carPrice,
        resaleValue: costs.resaleValue,
        ownershipYears: costs.ownershipYears,
        annualKm: costs.annualKm,
        maintenancePerYear: costs.maintenancePerYear,
        insurancePerYear: costs.insurancePerYear,
        otherCostPerKm: costs.otherCostPerKm,
        driverWagePerHour: wage,
        notes: notes,
      ));
    } else {
      await profiles.updateProfile(existing.copyWith(
        name: _nameCtrl.text.trim(),
        fuelType: _fuelType,
        engineDisplacement: displacement,
        fuelPricePerLiter: price,
        carPrice: costs.carPrice,
        resaleValue: costs.resaleValue,
        ownershipYears: costs.ownershipYears,
        annualKm: costs.annualKm,
        maintenancePerYear: costs.maintenancePerYear,
        insurancePerYear: costs.insurancePerYear,
        otherCostPerKm: costs.otherCostPerKm,
        driverWagePerHour: wage,
        notes: notes,
      ));
    }
    if (mounted) navigator.pop();
  }

  /// The k_m inputs as typed, on a throwaway profile, so the preview and the
  /// saved profile derive the per-km rates the same way.
  CarProfile _costProfile() {
    double read(TextEditingController ctrl) {
      final value = _parseNumber(ctrl.text) ?? 0;
      return value > 0 ? value : 0;
    }

    return CarProfile(
      name: '',
      fuelType: _fuelType,
      carPrice: read(_carPriceCtrl),
      resaleValue: read(_resaleCtrl),
      ownershipYears: read(_yearsCtrl),
      annualKm: read(_annualKmCtrl),
      maintenancePerYear: read(_maintenanceCtrl),
      insurancePerYear: read(_insuranceCtrl),
      otherCostPerKm: read(_otherCostCtrl),
    );
  }

  String? _validateResale(String? text) {
    final error = _validateRate(text);
    if (error != null) return error;
    final resale = _parseNumber(text) ?? 0;
    final price = _parseNumber(_carPriceCtrl.text) ?? 0;
    if (price > 0 && resale > price) return 'Above the price';
    return null;
  }

  Widget _rateField(
    TextEditingController controller,
    String label, {
    String? helper,
    IconData? icon,
    FormFieldValidator<String> validator = _validateRate,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        prefixIcon: icon != null ? Icon(icon) : null,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: _decimalInput,
      validator: validator,
      style: const TextStyle(color: Colors.white),
    );
  }

  Widget _fieldPair(Widget left, Widget right) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 12),
        Expanded(child: right),
      ],
    );
  }

  /// k_m as the profile will compute it, part by part.
  Widget _costPreview() {
    return ListenableBuilder(
      listenable: _costInputs,
      builder: (context, _) {
        final costs = _costProfile().nonFuelCosts;
        final parts = costs.parts;
        final text = parts.isEmpty
            ? 'Fill in any of these to add car costs per km.'
            : '= ${formatCostPerKm(costs.total)}  ('
                '${parts.map((p) => '${p.$1} ${formatCost(p.$2)}').join(', ')})';
        return Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        );
      },
    );
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
                    v == null || v.trim().isEmpty ? 'Name required' : null,
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
              TextFormField(
                controller: _displacementCtrl,
                decoration: const InputDecoration(
                  labelText: 'Displacement (L)',
                  prefixIcon: Icon(Icons.settings),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: _decimalInput,
                validator: _validateDisplacement,
                style: const TextStyle(color: Colors.white),
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
                inputFormatters: _decimalInput,
                validator: _validatePrice,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 14),
              const SizedBox(height: 22),
              Text(
                'CAR RUNNING COSTS (OPTIONAL)',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              // Depreciation = (price − resale) / (years × km per year).
              _fieldPair(
                _rateField(_carPriceCtrl, 'Car price',
                    icon: Icons.directions_car_filled),
                _rateField(_resaleCtrl, 'Resale value',
                    helper: 'Expected when sold', validator: _validateResale),
              ),
              const SizedBox(height: 14),
              _fieldPair(
                _rateField(_yearsCtrl, 'Years kept', icon: Icons.event),
                _rateField(_annualKmCtrl, 'Km per year', icon: Icons.speed),
              ),
              const SizedBox(height: 14),
              _fieldPair(
                _rateField(_maintenanceCtrl, 'Maintenance / year',
                    helper: 'Service, repairs, tyres', icon: Icons.build),
                _rateField(_insuranceCtrl, 'Insurance & tax / year',
                    icon: Icons.shield_outlined),
              ),
              const SizedBox(height: 14),
              // Leave all costs or the wage blank and trips show the fuel cost
              // alone.
              _fieldPair(
                _rateField(_otherCostCtrl, 'Other cost / km',
                    helper: 'Parking, tolls', icon: Icons.more_horiz),
                _rateField(_wageCtrl, 'Driver wage / h',
                    helper: 'Optional', icon: Icons.schedule),
              ),
              const SizedBox(height: 10),
              _costPreview(),
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
