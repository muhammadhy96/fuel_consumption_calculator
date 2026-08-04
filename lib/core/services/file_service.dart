import 'dart:async';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/trip_sample.dart';

/// Header row of every trip CSV.
///
/// Shared by the bulk [FileService.saveTripSamples] path and the streaming
/// [TripCsvWriter] so the two can never drift apart — [FileService.loadTripSamples]
/// and `TripSample.fromCsvRow` depend on this exact column layout.
const List<String> _tripCsvHeader = [
  'Time (s)',
  'RPM',
  'MAP (kPa)',
  'Speed (km/h)',
  'IAT (K)',
  'Fuel (mL/s)',
  'Engine Load (%)',
  'MAF (g/s)',
  'Eq Ratio',
];

/// Incremental trip CSV writer.
///
/// Rows are encoded and pushed to an [IOSink] as they arrive, so a multi-hour
/// trip never materialises as one giant string on the main isolate and an
/// unexpected termination still leaves everything recorded so far on disk.
///
/// Every failure is absorbed: the writer simply marks itself failed, [close]
/// returns null, and the caller falls back to a bulk write.
class TripCsvWriter {
  TripCsvWriter._(this._file, this._sink) {
    unawaited(_watchSink());
  }

  final File _file;
  final IOSink _sink;

  bool _failed = false;
  bool _closed = false;
  Future<String?>? _closeFuture;

  /// Absolute path of the CSV being written.
  String get path => _file.path;

  /// True while the writer is still accepting rows.
  bool get isOpen => !_closed && !_failed;

  /// Appends [sample] as a CSV row.
  ///
  /// Called at OBD frame rate: it never throws and never awaits. On any
  /// failure the writer is marked failed so the caller degrades to the bulk
  /// save at stop time.
  void addSample(TripSample sample) {
    _writeRow(sample.toCsvRow());
  }

  /// Flushes and closes the file.
  ///
  /// Returns the CSV path, or null when the trip could not be written and the
  /// caller must fall back to [FileService.saveTripSamples]. Safe to call more
  /// than once — later calls return the first result.
  Future<String?> close() => _closeFuture ??= _closeInternal();

  void _writeHeader() {
    _writeRow(_tripCsvHeader);
  }

  void _writeRow(List<dynamic> row) {
    if (!isOpen) return;
    try {
      _sink.write(_encodeRow(row));
    } catch (err) {
      _markFailed('row write failed', err);
    }
  }

  Future<String?> _closeInternal() async {
    _closed = true;
    try {
      await _sink.flush();
    } catch (err) {
      _markFailed('flush failed', err);
    }
    try {
      await _sink.close();
    } catch (err) {
      _markFailed('close failed', err);
    }
    return _failed ? null : _file.path;
  }

  /// Buffered writes report their errors asynchronously through [IOSink.done];
  /// listening keeps them from surfacing as unhandled and flips [isOpen].
  Future<void> _watchSink() async {
    try {
      await _sink.done;
    } catch (err) {
      _markFailed('stream failed', err);
    }
  }

  void _markFailed(String reason, Object err) {
    _failed = true;
    debugPrint('Trip CSV $reason for ${_file.path}: $err');
  }

  /// Encodes one row plus the converter's end-of-line. The trailing `null` row
  /// is the csv package's own idiom for "terminate this line" (see
  /// `List2CsvSink.add`), which keeps quoting and line endings byte-identical
  /// to the bulk [FileService.saveTripSamples] output.
  static String _encodeRow(List<dynamic> row) =>
      const ListToCsvConverter().convert(<List<dynamic>?>[row, null]);
}

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

  Future<Directory> _resolveExportDirectory() async {
    final baseDir = await _resolveOutputDirectory();
    final exportDir = Directory(p.join(baseDir.path, 'FuelTrips'));
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    return exportDir;
  }

  String _tripFileName(String profileId) =>
      '${profileId}_trip_${DateTime.now().millisecondsSinceEpoch}.csv';

  /// Opens a [TripCsvWriter] with the header row already written, creating the
  /// export directory if needed.
  ///
  /// Returns null when the file could not be opened; the caller then keeps
  /// buffering in memory and falls back to [saveTripSamples] at stop time.
  Future<TripCsvWriter?> openTripWriter(String profileId) async {
    try {
      final exportDir = await _resolveExportDirectory();
      final file = File(p.join(exportDir.path, _tripFileName(profileId)));
      final writer = TripCsvWriter._(file, file.openWrite());
      writer._writeHeader();
      if (!writer.isOpen) {
        await writer.close();
        return null;
      }
      return writer;
    } catch (err) {
      debugPrint('Failed to open streaming trip CSV: $err');
      return null;
    }
  }

  Future<String> saveTripSamples(String profileId, List<TripSample> samples) async {
    final exportDir = await _resolveExportDirectory();
    final file = File(p.join(exportDir.path, _tripFileName(profileId)));
    final rows = [
      _tripCsvHeader,
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
