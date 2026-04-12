import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/trip_sample.dart';

class FileService {
  Directory? _cachedDirectory;

  Future<Directory> _resolveOutputDirectory() async {
    if (_cachedDirectory != null) return _cachedDirectory!;

    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (_) {
      downloads = null;
    }
    if (downloads != null) {
      _cachedDirectory = downloads;
      return downloads;
    }

    String? selectedPath;
    try {
      selectedPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select folder to save trip exports',
      );
    } catch (_) {
      selectedPath = null;
    }
    if (selectedPath != null) {
      _cachedDirectory = Directory(selectedPath);
      return _cachedDirectory!;
    }

    final fallback = await getApplicationDocumentsDirectory();
    _cachedDirectory = fallback;
    return fallback;
  }

  Future<String> saveTripSamples(String profileId, List<TripSample> samples) async {
    final baseDir = await _resolveOutputDirectory();
    final exportDir = Directory(p.join(baseDir.path, 'FuelTrips'));
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    final fileName =
        '${profileId}_trip_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File(p.join(exportDir.path, fileName));
    final rows = [
      [
        'Time (s)',
        'RPM',
        'MAP (kPa)',
        'Speed (km/h)',
        'IAT (K)',
        'Fuel (mL/s)',
        'Engine Load (%)',
        'MAF (g/s)',
        'Eq Ratio'
      ],
      ...samples.map((s) => s.toCsvRow()),
    ];
    await file.writeAsString(const ListToCsvConverter().convert(rows));
    return file.path;
  }

  Future<List<TripSample>> loadTripSamples(String path) async {
    final file = File(path);
    if (!await file.exists()) return [];

    try {
      final content = await file.readAsString();
      final rows = const CsvToListConverter().convert(content);
      if (rows.length <= 1) return [];

      final samples = <TripSample>[];
      for (final row in rows.skip(1)) {
        if (row.length < 5) {
          continue;
        }
        try {
          samples.add(TripSample.fromCsvRow(List<dynamic>.from(row)));
        } catch (_) {
          // Skip malformed sample rows to keep the trip readable.
        }
      }
      return samples;
    } catch (_) {
      return [];
    }
  }
}
