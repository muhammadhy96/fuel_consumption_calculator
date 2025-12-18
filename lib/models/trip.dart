class Trip {
  Trip({
    required this.id,
    required this.profileId,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
    required this.totalFuelMl,
    required this.avgFuelMlPerSec,
    this.dataFilePath,
  });

  final String id;
  final String profileId;
  final DateTime startTime;
  final DateTime endTime;
  final int durationSeconds;
  final double totalFuelMl;
  final double avgFuelMlPerSec;
  final String? dataFilePath;

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
      'dataFilePath': dataFilePath,
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
      dataFilePath: map['dataFilePath'] as String?,
    );
  }
}
