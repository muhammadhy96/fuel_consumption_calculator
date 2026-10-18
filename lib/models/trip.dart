class Trip {
  Trip({
    required this.id,
    required this.profileId,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
    required this.totalFuelMl,
    required this.avgFuelMlPerSec,
    this.distanceKm = 0,
    this.avgConsumptionLPer100Km = 0,
    this.dataFilePath,
    this.inProgress = false,
    this.fuelPricePerLiter = 0,
    this.nonFuelCostPerKm = 0,
    this.driverWagePerHour = 0,
    this.totalCost,
    this.costPerKm,
    this.fuelCostShare,
  });

  final String id;
  final String profileId;
  final DateTime startTime;
  final DateTime endTime;
  final int durationSeconds;
  final double totalFuelMl;
  final double avgFuelMlPerSec;
  final double distanceKm;
  final double avgConsumptionLPer100Km;
  final String? dataFilePath;

  /// True for the provisional record saved while a trip is recording. One
  /// still set at launch means the app died before STOP.
  final bool inProgress;

  /// Rates of the trip cost model (eq. 3-34) as they were on the profile when
  /// the trip was recorded: P_fuel, k_m and k_t. 0 when not set.
  final double fuelPricePerLiter;
  final double nonFuelCostPerKm;
  final double driverWagePerHour;

  /// C_trip from [TripCost], or the fuel cost alone when [costIsFullModel] is
  /// false. Null when no fuel price was set, and on trips saved before costs
  /// were stored.
  final double? totalCost;

  /// C_trip / S. Null when [totalCost] is, or no distance was covered.
  final double? costPerKm;

  /// ω = (V_f × P_fuel) / C_trip. Null unless [costIsFullModel].
  final double? fuelCostShare;

  /// Whether [totalCost] holds all three terms of eq. 3-34.
  bool get costIsFullModel =>
      totalCost != null && nonFuelCostPerKm > 0 && driverWagePerHour > 0;

  double get totalFuelLiters => totalFuelMl / 1000;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'profileId': profileId,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'durationSeconds': durationSeconds,
      'totalFuelMl': totalFuelMl,
      'avgFuelMlPerSec': avgFuelMlPerSec,
      'distanceKm': distanceKm,
      'avgConsumptionLPer100Km': avgConsumptionLPer100Km,
      'dataFilePath': dataFilePath,
      'inProgress': inProgress,
      'fuelPricePerLiter': fuelPricePerLiter,
      'nonFuelCostPerKm': nonFuelCostPerKm,
      'driverWagePerHour': driverWagePerHour,
      'totalCost': totalCost,
      'costPerKm': costPerKm,
      'fuelCostShare': fuelCostShare,
    };
  }

  factory Trip.fromMap(Map<String, dynamic> map) {
    return Trip(
      id: map['id'] as String,
      profileId: map['profileId'] as String,
      startTime: DateTime.tryParse(map['startTime'] as String? ?? '') ??
          DateTime.now(),
      endTime: DateTime.tryParse(map['endTime'] as String? ?? '') ??
          DateTime.now(),
      durationSeconds: map['durationSeconds'] as int? ?? 0,
      totalFuelMl: (map['totalFuelMl'] as num?)?.toDouble() ?? 0,
      avgFuelMlPerSec: (map['avgFuelMlPerSec'] as num?)?.toDouble() ?? 0,
      distanceKm: (map['distanceKm'] as num?)?.toDouble() ?? 0,
      avgConsumptionLPer100Km:
          (map['avgConsumptionLPer100Km'] as num?)?.toDouble() ?? 0,
      dataFilePath: map['dataFilePath'] as String?,
      inProgress: map['inProgress'] as bool? ?? false,
      // Absent from trips saved before the full cost model.
      fuelPricePerLiter:
          (map['fuelPricePerLiter'] as num?)?.toDouble() ?? 0,
      nonFuelCostPerKm: (map['nonFuelCostPerKm'] as num?)?.toDouble() ?? 0,
      driverWagePerHour:
          (map['driverWagePerHour'] as num?)?.toDouble() ?? 0,
      totalCost: (map['totalCost'] as num?)?.toDouble(),
      costPerKm: (map['costPerKm'] as num?)?.toDouble(),
      fuelCostShare: (map['fuelCostShare'] as num?)?.toDouble(),
    );
  }
}
