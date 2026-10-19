import 'non_fuel_costs.dart';

class CarProfile {
  CarProfile({
    String? id,
    required this.name,
    required this.fuelType,
    this.engineDisplacement,
    this.notes,
    this.fuelPricePerLiter = 0,
    this.carPrice = 0,
    this.resaleValue = 0,
    this.ownershipYears = 0,
    this.annualKm = 0,
    this.maintenancePerYear = 0,
    this.insurancePerYear = 0,
    this.otherCostPerKm = 0,
    this.driverWagePerHour = 0,
    DateTime? createdAt,
  })  : id = id ?? 'profile-${DateTime.now().millisecondsSinceEpoch}',
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final String name;
  final String fuelType;
  final double? engineDisplacement;
  final double fuelPricePerLiter;

  /// Inputs of k_m (eq. 3-34), as an owner knows them; see [nonFuelCosts].
  /// 0 when not set.
  final double carPrice;
  final double resaleValue;
  final double ownershipYears;
  final double annualKm;
  final double maintenancePerYear;
  final double insurancePerYear;
  final double otherCostPerKm;

  /// k_t of the trip cost model (eq. 3-34). 0 when not set.
  final double driverWagePerHour;
  final String? notes;
  final DateTime createdAt;

  /// Used by the speed-density estimate when a profile has no displacement.
  static const double assumedDisplacementLiters = 2.0;

  double get effectiveDisplacementLiters =>
      engineDisplacement ?? assumedDisplacementLiters;

  /// e.g. `1.6L`, or `2.0L assumed` when the profile has none.
  String get displacementLabel => engineDisplacement != null
      ? '${engineDisplacement!.toStringAsFixed(1)}L'
      : '${assumedDisplacementLiters.toStringAsFixed(1)}L assumed';

  /// k_m per part. Yearly amounts are spread over [annualKm], and the loss in
  /// value over the km driven in [ownershipYears]; a part whose inputs are
  /// incomplete is 0.
  NonFuelCosts get nonFuelCosts {
    final hasKm = annualKm > 0;
    final ownedKm = annualKm * ownershipYears;
    final lostValue = carPrice - resaleValue;
    return NonFuelCosts(
      depreciation: ownedKm > 0 && lostValue > 0 ? lostValue / ownedKm : 0,
      maintenance: hasKm ? maintenancePerYear / annualKm : 0,
      insurance: hasKm ? insurancePerYear / annualKm : 0,
      other: otherCostPerKm,
    );
  }

  /// k_m.
  double get nonFuelCostPerKm => nonFuelCosts.total;

  CarProfile copyWith({
    String? name,
    String? fuelType,
    double? engineDisplacement,
    double? fuelPricePerLiter,
    double? carPrice,
    double? resaleValue,
    double? ownershipYears,
    double? annualKm,
    double? maintenancePerYear,
    double? insurancePerYear,
    double? otherCostPerKm,
    double? driverWagePerHour,
    String? notes,
  }) {
    return CarProfile(
      id: id,
      name: name ?? this.name,
      fuelType: fuelType ?? this.fuelType,
      engineDisplacement: engineDisplacement ?? this.engineDisplacement,
      fuelPricePerLiter: fuelPricePerLiter ?? this.fuelPricePerLiter,
      carPrice: carPrice ?? this.carPrice,
      resaleValue: resaleValue ?? this.resaleValue,
      ownershipYears: ownershipYears ?? this.ownershipYears,
      annualKm: annualKm ?? this.annualKm,
      maintenancePerYear: maintenancePerYear ?? this.maintenancePerYear,
      insurancePerYear: insurancePerYear ?? this.insurancePerYear,
      otherCostPerKm: otherCostPerKm ?? this.otherCostPerKm,
      driverWagePerHour: driverWagePerHour ?? this.driverWagePerHour,
      notes: notes ?? this.notes,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'fuelType': fuelType,
      'engineDisplacement': engineDisplacement,
      'fuelPricePerLiter': fuelPricePerLiter,
      'carPrice': carPrice,
      'resaleValue': resaleValue,
      'ownershipYears': ownershipYears,
      'annualKm': annualKm,
      'maintenancePerYear': maintenancePerYear,
      'insurancePerYear': insurancePerYear,
      'otherCostPerKm': otherCostPerKm,
      'driverWagePerHour': driverWagePerHour,
      'notes': notes,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory CarProfile.fromMap(Map<String, dynamic> map) {
    double rate(String key) => (map[key] as num?)?.toDouble() ?? 0;
    return CarProfile(
      id: map['id'] as String?,
      name: map['name'] as String? ?? '',
      fuelType: map['fuelType'] as String? ?? 'Petrol',
      engineDisplacement: (map['engineDisplacement'] as num?)?.toDouble(),
      fuelPricePerLiter: rate('fuelPricePerLiter'),
      // All absent from profiles saved before the k_m breakdown.
      carPrice: rate('carPrice'),
      resaleValue: rate('resaleValue'),
      ownershipYears: rate('ownershipYears'),
      annualKm: rate('annualKm'),
      maintenancePerYear: rate('maintenancePerYear'),
      insurancePerYear: rate('insurancePerYear'),
      // Those profiles held k_m as one number, which carries over as "other".
      otherCostPerKm: map.containsKey('otherCostPerKm')
          ? rate('otherCostPerKm')
          : rate('nonFuelCostPerKm'),
      driverWagePerHour: rate('driverWagePerHour'),
      notes: map['notes'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
