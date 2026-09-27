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
    );
  }
}
