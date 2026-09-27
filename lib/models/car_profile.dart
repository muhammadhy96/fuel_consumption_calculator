class CarProfile {
  CarProfile({
    String? id,
    required this.name,
    required this.fuelType,
    this.engineDisplacement,
    this.notes,
    this.volumetricEfficiency = 85,
    this.fuelPricePerLiter = 0,
    DateTime? createdAt,
  })  : id = id ?? 'profile-${DateTime.now().millisecondsSinceEpoch}',
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final String name;
  final String fuelType;
  final double? engineDisplacement;
  final double volumetricEfficiency;
  final double fuelPricePerLiter;
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

  CarProfile copyWith({
    String? name,
    String? fuelType,
    double? engineDisplacement,
    double? volumetricEfficiency,
    double? fuelPricePerLiter,
    String? notes,
  }) {
    return CarProfile(
      id: id,
      name: name ?? this.name,
      fuelType: fuelType ?? this.fuelType,
      engineDisplacement: engineDisplacement ?? this.engineDisplacement,
      volumetricEfficiency: volumetricEfficiency ?? this.volumetricEfficiency,
      fuelPricePerLiter: fuelPricePerLiter ?? this.fuelPricePerLiter,
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
      'volumetricEfficiency': volumetricEfficiency,
      'fuelPricePerLiter': fuelPricePerLiter,
      'notes': notes,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory CarProfile.fromMap(Map<String, dynamic> map) {
    return CarProfile(
      id: map['id'] as String?,
      name: map['name'] as String? ?? '',
      fuelType: map['fuelType'] as String? ?? 'Petrol',
      engineDisplacement: (map['engineDisplacement'] as num?)?.toDouble(),
      volumetricEfficiency:
          (map['volumetricEfficiency'] as num?)?.toDouble() ?? 85,
      fuelPricePerLiter:
          (map['fuelPricePerLiter'] as num?)?.toDouble() ?? 0,
      notes: map['notes'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
