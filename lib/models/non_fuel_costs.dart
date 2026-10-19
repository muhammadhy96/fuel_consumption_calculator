/// k_m of the trip cost model (eq. 3-34), split into the parts it is made of.
/// Every value is a cost per km, in the currency of the fuel price.
///
/// A profile derives these from what an owner actually knows (purchase price,
/// yearly bills, km per year); each trip keeps the rates it was recorded with,
/// so editing the profile later never rewrites old trips.
class NonFuelCosts {
  const NonFuelCosts({
    this.depreciation = 0,
    this.maintenance = 0,
    this.insurance = 0,
    this.other = 0,
  });

  static const NonFuelCosts none = NonFuelCosts();

  /// (purchase price − resale value) / km driven while owned.
  final double depreciation;

  /// Servicing, repairs, oil and tyres.
  final double maintenance;

  /// Insurance, registration and road tax.
  final double insurance;

  /// Anything else per km. Also holds the single unsplit k_m of profiles and
  /// trips saved before the breakdown existed.
  final double other;

  /// k_m.
  double get total => depreciation + maintenance + insurance + other;

  /// Label and rate of each part, in display order, unset parts left out.
  List<(String, double)> get parts => [
        if (depreciation > 0) ('Depreciation', depreciation),
        if (maintenance > 0) ('Maintenance', maintenance),
        if (insurance > 0) ('Insurance & tax', insurance),
        if (other > 0) ('Other costs', other),
      ];

  Map<String, dynamic> toMap() => {
        'depreciation': depreciation,
        'maintenance': maintenance,
        'insurance': insurance,
        'other': other,
      };

  factory NonFuelCosts.fromMap(Map<String, dynamic> map) => NonFuelCosts(
        depreciation: (map['depreciation'] as num?)?.toDouble() ?? 0,
        maintenance: (map['maintenance'] as num?)?.toDouble() ?? 0,
        insurance: (map['insurance'] as num?)?.toDouble() ?? 0,
        other: (map['other'] as num?)?.toDouble() ?? 0,
      );
}
