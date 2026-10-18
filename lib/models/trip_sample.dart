class TripSample {
  TripSample({
    required this.timeSeconds,
    required this.rpm,
    required this.mapKpa,
    required this.speedKph,
    required this.iatKelvin,
    required this.fuelMlPerSec,
    required this.mafGramsPerSec,
    required this.equivRatio,
    this.stftPercent = 0,
    this.ltftPercent = 0,
    this.fuelSystemStatus = 0,
    this.absoluteLoadPercent = 0,
  });

  final double timeSeconds;
  final double rpm;
  final double mapKpa;
  final double speedKph;
  final double iatKelvin;
  final double fuelMlPerSec;
  final double mafGramsPerSec;
  final double equivRatio;
  final double stftPercent;
  final double ltftPercent;

  /// Raw PID 0103 bank-1 byte; 0 when unsupported or not yet read.
  final int fuelSystemStatus;
  final double absoluteLoadPercent;

  /// Column count of the layout [toCsvRow] writes.
  static const int csvColumnCount = 12;

  List<dynamic> toCsvRow() => [
        timeSeconds,
        rpm,
        mapKpa,
        speedKph,
        iatKelvin,
        fuelMlPerSec,
        mafGramsPerSec,
        equivRatio,
        stftPercent,
        ltftPercent,
        fuelSystemStatus,
        absoluteLoadPercent,
      ];

  /// Reads a row of any layout the app has written.
  ///
  /// Current layout, 12 columns:
  ///   time, RPM, MAP, speed, IAT, fuel, MAF, λ, STFT, LTFT, 0103, abs load
  ///
  /// Earlier layouts logged calculated engine load (0104) at index 6, shifting
  /// everything after it by one, and grew by appending columns: 5 (no speed),
  /// 6, 9 (to λ), 11 (+ trims), 12 (+ 0103) and 13 (+ abs load).
  ///
  /// 12 columns is both the current layout and a legacy one; the file header
  /// settles it through [hasEngineLoadColumn]. Without it, a 12-column row is
  /// read as the current layout. Rows under 9 columns predate engine load and
  /// share the current layout's first six columns, so they always parse.
  factory TripSample.fromCsvRow(
    List<dynamic> row, {
    bool? hasEngineLoadColumn,
  }) {
    final isCurrentLayout = hasEngineLoadColumn == null
        ? row.length == csvColumnCount
        : !hasEngineLoadColumn && row.length >= 9;
    return isCurrentLayout
        ? TripSample._fromCurrentRow(row)
        : TripSample._fromLegacyRow(row);
  }

  factory TripSample._fromCurrentRow(List<dynamic> row) {
    return TripSample(
      timeSeconds: _num(row[0]),
      rpm: _num(row[1]),
      mapKpa: _num(row[2]),
      speedKph: _num(row[3]),
      iatKelvin: _num(row[4]),
      fuelMlPerSec: _num(row[5]),
      mafGramsPerSec: _num(row[6]),
      equivRatio: _num(row[7]),
      stftPercent: _num(row[8]),
      ltftPercent: _num(row[9]),
      fuelSystemStatus: (row[10] as num).toInt(),
      absoluteLoadPercent: _num(row[11]),
    );
  }

  /// Layouts that carried engine load at index 6. The value is skipped.
  factory TripSample._fromLegacyRow(List<dynamic> row) {
    final hasExtended = row.length >= 9;
    final hasTrims = row.length >= 11;
    final hasFuelStatus = row.length >= 12;
    final hasAbsLoad = row.length >= 13;
    final hasSpeed = row.length >= 6;
    final iatIndex = hasSpeed ? 4 : 3;
    final fuelIndex = hasSpeed ? 5 : 4;
    return TripSample(
      timeSeconds: _num(row[0]),
      rpm: _num(row[1]),
      mapKpa: _num(row[2]),
      speedKph: hasSpeed ? _num(row[3]) : 0.0,
      iatKelvin: _num(row[iatIndex]),
      fuelMlPerSec: _num(row[fuelIndex]),
      mafGramsPerSec: hasExtended ? _num(row[7]) : 0.0,
      equivRatio: hasExtended ? _num(row[8]) : 1.0,
      stftPercent: hasTrims ? _num(row[9]) : 0.0,
      ltftPercent: hasTrims ? _num(row[10]) : 0.0,
      fuelSystemStatus: hasFuelStatus ? (row[11] as num).toInt() : 0,
      absoluteLoadPercent: hasAbsLoad ? _num(row[12]) : 0.0,
    );
  }

  static double _num(dynamic value) => (value as num).toDouble();
}
