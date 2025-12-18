class TripSample {
  TripSample({
    required this.timeSeconds,
    required this.rpm,
    required this.mapKpa,
    required this.iatKelvin,
    required this.fuelMlPerSec,
  });

  final double timeSeconds;
  final double rpm;
  final double mapKpa;
  final double iatKelvin;
  final double fuelMlPerSec;

  List<dynamic> toCsvRow() => [
        timeSeconds,
        rpm,
        mapKpa,
        iatKelvin,
        fuelMlPerSec,
      ];

  factory TripSample.fromCsvRow(List<dynamic> row) {
    return TripSample(
      timeSeconds: (row[0] as num).toDouble(),
      rpm: (row[1] as num).toDouble(),
      mapKpa: (row[2] as num).toDouble(),
      iatKelvin: (row[3] as num).toDouble(),
      fuelMlPerSec: (row[4] as num).toDouble(),
    );
  }
}
