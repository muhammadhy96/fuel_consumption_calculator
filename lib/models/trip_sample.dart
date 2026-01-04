class TripSample {
  TripSample({
    required this.timeSeconds,
    required this.rpm,
    required this.mapKpa,
    required this.speedKph,
    required this.iatKelvin,
    required this.fuelMlPerSec,
  });

  final double timeSeconds;
  final double rpm;
  final double mapKpa;
  final double speedKph;
  final double iatKelvin;
  final double fuelMlPerSec;

  List<dynamic> toCsvRow() => [
        timeSeconds,
        rpm,
        mapKpa,
        speedKph,
        iatKelvin,
        fuelMlPerSec,
      ];

  factory TripSample.fromCsvRow(List<dynamic> row) {
    final hasSpeed = row.length >= 6;
    final double speed = hasSpeed ? (row[3] as num).toDouble() : 0.0;
    final iatIndex = hasSpeed ? 4 : 3;
    final fuelIndex = hasSpeed ? 5 : 4;
    return TripSample(
      timeSeconds: (row[0] as num).toDouble(),
      rpm: (row[1] as num).toDouble(),
      mapKpa: (row[2] as num).toDouble(),
      speedKph: speed,
      iatKelvin: (row[iatIndex] as num).toDouble(),
      fuelMlPerSec: (row[fuelIndex] as num).toDouble(),
    );
  }
}
