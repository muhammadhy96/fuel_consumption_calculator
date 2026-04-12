class TripSample {
  TripSample({
    required this.timeSeconds,
    required this.rpm,
    required this.mapKpa,
    required this.speedKph,
    required this.iatKelvin,
    required this.fuelMlPerSec,
    required this.engineLoadPercent,
    required this.mafGramsPerSec,
    required this.equivRatio,
  });

  final double timeSeconds;
  final double rpm;
  final double mapKpa;
  final double speedKph;
  final double iatKelvin;
  final double fuelMlPerSec;
  final double engineLoadPercent;
  final double mafGramsPerSec;
  final double equivRatio;

  List<dynamic> toCsvRow() => [
        timeSeconds,
        rpm,
        mapKpa,
        speedKph,
        iatKelvin,
        fuelMlPerSec,
        engineLoadPercent,
        mafGramsPerSec,
        equivRatio,
      ];

  factory TripSample.fromCsvRow(List<dynamic> row) {
    final hasExtended = row.length >= 9;
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
      engineLoadPercent: hasExtended ? (row[6] as num).toDouble() : 0.0,
      mafGramsPerSec: hasExtended ? (row[7] as num).toDouble() : 0.0,
      equivRatio: hasExtended ? (row[8] as num).toDouble() : 1.0,
    );
  }
}
