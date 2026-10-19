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
    this.gpsSpeedKph,
    this.gpsSpeedAccuracyKph,
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

  /// Ground speed from the phone's GPS, or null when it had no fresh fix.
  final double? gpsSpeedKph;

  /// 1-σ accuracy of [gpsSpeedKph], or null when the phone does not report it.
  final double? gpsSpeedAccuracyKph;

  /// The speed the trip distance is integrated from.
  ///
  /// GPS ground speed when there is a fix: the OBD speed is wheel speed, which
  /// reads high when the driven wheels slip and drifts with tyre wear and size.
  /// A car whose OBD speed is 0 is standing, so it stays 0 and GPS jitter at a
  /// red light adds no distance. Without a fix, the OBD speed.
  double get distanceSpeedKph {
    final gps = gpsSpeedKph;
    if (gps == null || speedKph <= 0) return speedKph;
    return gps;
  }

  /// Column count of the layout [toCsvRow] writes.
  static const int csvColumnCount = 14;

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
        // Blank cells when there was no fix.
        gpsSpeedKph,
        gpsSpeedAccuracyKph,
      ];

  /// Reads a row of any layout the app has written.
  ///
  /// Current layout, 14 columns:
  ///   time, RPM, MAP, speed, IAT, fuel, MAF, λ, STFT, LTFT, 0103, abs load,
  ///   GPS speed, GPS speed accuracy
  ///
  /// The same layout without the two GPS columns (12) came before it. Earlier
  /// layouts logged calculated engine load (0104) at index 6, shifting
  /// everything after it by one, and grew by appending columns: 5 (no speed),
  /// 6, 9 (to λ), 11 (+ trims), 12 (+ 0103) and 13 (+ abs load).
  ///
  /// 12 columns is both a current-layout row without GPS and a legacy one; the
  /// file header settles it through [hasEngineLoadColumn]. Without it, 12 and
  /// 14 columns are read as the current layout. Rows under 9 columns predate
  /// engine load and share the current layout's first six columns, so they
  /// always parse.
  factory TripSample.fromCsvRow(
    List<dynamic> row, {
    bool? hasEngineLoadColumn,
  }) {
    final isCurrentLayout = hasEngineLoadColumn == null
        ? row.length == 12 || row.length == csvColumnCount
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
      gpsSpeedKph: row.length > 12 ? _numOrNull(row[12]) : null,
      gpsSpeedAccuracyKph: row.length > 13 ? _numOrNull(row[13]) : null,
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

  /// A blank cell reads back as an empty string.
  static double? _numOrNull(dynamic value) =>
      value is num ? value.toDouble() : null;
}
