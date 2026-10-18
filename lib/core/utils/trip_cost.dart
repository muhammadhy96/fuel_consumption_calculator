/// Trip cost model, thesis section 4-8, equation 3-34:
///
///   C_trip = V_f × P_fuel  +  S × k_m  +  T × k_t
///
///   V_f    litres consumed          P_fuel  price per litre
///   S      distance (km)            k_m     non-fuel cost per km
///   T      duration (h)             k_t     driver wage per hour
///
/// and the fuel share of it,  ω = (V_f × P_fuel) / C_trip.
///
/// Until both k_m and k_t are set the distance and time terms are unknown, not
/// zero, so the cost falls back to the fuel term alone and [isFullModel] is
/// false: a total missing two of its three terms would read as a real one.
class TripCost {
  const TripCost._({
    required this.fuelCost,
    required this.distanceCost,
    required this.timeCost,
    required this.distanceKm,
    required this.isFullModel,
  });

  /// Null when [fuelPricePerLiter] is not set: without P_fuel there is no
  /// term to report.
  static TripCost? compute({
    required double fuelLiters,
    required double distanceKm,
    required double durationHours,
    required double fuelPricePerLiter,
    required double nonFuelCostPerKm,
    required double driverWagePerHour,
  }) {
    if (!(fuelPricePerLiter > 0)) return null;
    final isFullModel = nonFuelCostPerKm > 0 && driverWagePerHour > 0;
    return TripCost._(
      fuelCost: fuelLiters * fuelPricePerLiter,
      distanceCost: isFullModel ? distanceKm * nonFuelCostPerKm : 0,
      timeCost: isFullModel ? durationHours * driverWagePerHour : 0,
      distanceKm: distanceKm,
      isFullModel: isFullModel,
    );
  }

  /// V_f × P_fuel.
  final double fuelCost;

  /// S × k_m; 0 unless [isFullModel].
  final double distanceCost;

  /// T × k_t; 0 unless [isFullModel].
  final double timeCost;

  /// S, kept so [costPerKm] needs nothing else.
  final double distanceKm;

  /// True when all three terms are in [total]; false means fuel cost alone.
  final bool isFullModel;

  /// C_trip, or V_f × P_fuel alone when not [isFullModel].
  double get total => fuelCost + distanceCost + timeCost;

  /// C_trip / S; null before any distance is covered.
  double? get costPerKm => distanceKm > 0 ? total / distanceKm : null;

  /// ω = (V_f × P_fuel) / C_trip; null when only the fuel term is known, as
  /// it would then be 1 by construction.
  double? get fuelShare => isFullModel && total > 0 ? fuelCost / total : null;
}
