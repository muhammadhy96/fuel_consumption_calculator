class CarProfile {
  CarProfile({
    String? id,
    required this.name,
    required this.fuelType,
    this.engineDisplacement,
    this.notes,
    this.volumetricEfficiency = 85,
    DateTime? createdAt,
  })  : id = id ?? 'profile-${DateTime.now().millisecondsSinceEpoch}',
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final String name;
  final String fuelType;
  final double? engineDisplacement;
  final double volumetricEfficiency;
  final String? notes;
  final DateTime createdAt;

  CarProfile copyWith({
    String? name,
    String? fuelType,
    double? engineDisplacement,
    double? volumetricEfficiency,
    String? notes,
  }) {
    return CarProfile(
      id: id,
      name: name ?? this.name,
      fuelType: fuelType ?? this.fuelType,
      engineDisplacement: engineDisplacement ?? this.engineDisplacement,
      volumetricEfficiency: volumetricEfficiency ?? this.volumetricEfficiency,
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
      notes: map['notes'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
