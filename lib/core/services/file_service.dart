import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
  'STFT (%)',
  'LTFT (%)',
  'Fuel System Status',
  'Abs Load (%)',
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

/// Outcome of an export, so the UI can say what actually happened rather than
/// guessing.
enum TripExportStatus {
  /// The trip left the app: shared, or written to the chosen location.
  success,

  /// The driver dismissed the share sheet or the save dialog.
  cancelled,

  /// The trip has no CSV on disk (recording failed, or the file was removed).
  missingFile,

  /// Something went wrong; [TripExportResult.message] says what.
  failed,
}

class TripExportResult {
  const TripExportResult(this.status, {this.message, this.savedPath});

  const TripExportResult.success({this.savedPath})
      : status = TripExportStatus.success,
        message = null;

  final TripExportStatus status;

  /// Human-readable detail for [TripExportStatus.failed].
  final String? message;

  /// Where the copy landed, when the platform tells us.
  final String? savedPath;

  bool get isSuccess => status == TripExportStatus.success;
}

class FileService {
  Directory? _cachedDirectory;

  /// Where trip CSVs are written.
  ///
  /// On Android and iOS this is always the app's own documents directory: it
  /// needs no permission and, crucially, never blocks. The previous fallback
  /// opened a system folder picker, which on mobile fired in the middle of
  /// [openTripWriter] at trip start and handed back a SAF tree URI that
  /// `dart:io` cannot write to — so the trip's CSV was lost. Getting a trip off
  /// the phone is handled explicitly by [shareTripCsv] and [saveTripCsvCopy].
  ///
  /// On desktop the real Downloads folder is used, falling back to a folder the
  /// user picks and then to documents.
  Future<Directory> _resolveOutputDirectory() async {
    if (_cachedDirectory != null) return _cachedDirectory!;

    if (Platform.isAndroid || Platform.isIOS) {
      final documents = await getApplicationDocumentsDirectory();
      _cachedDirectory = documents;
      return documents;
    }

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

  /// Builds a filename a human can recognise in a Downloads folder or an email
  /// attachment, e.g. `Golf_GTI_2026-09-22_14-05.csv`.
  static String exportFileName(String profileName, DateTime startTime) {
    final safeName = profileName
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final stamp = '${startTime.year.toString().padLeft(4, '0')}-'
        '${startTime.month.toString().padLeft(2, '0')}-'
        '${startTime.day.toString().padLeft(2, '0')}_'
        '${startTime.hour.toString().padLeft(2, '0')}-'
        '${startTime.minute.toString().padLeft(2, '0')}';
    final prefix = safeName.isEmpty ? 'trip' : safeName;
    return '${prefix}_$stamp.csv';
  }

  /// Hands the trip CSV to the system share sheet.
  ///
  /// The file is copied to a temp directory under [exportName] first, so the
  /// receiving app sees a readable name instead of the internal
  /// `profile-1712...._trip_1712....csv`.
  Future<TripExportResult> shareTripCsv(
    String? csvPath, {
    required String exportName,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    final source = await _readableCsv(csvPath);
    if (source == null) return const TripExportResult(TripExportStatus.missingFile);
    try {
      final staged = await _stageForExport(source, exportName);
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(staged.path, mimeType: 'text/csv', name: exportName)],
          subject: subject,
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      if (result.status == ShareResultStatus.dismissed) {
        return const TripExportResult(TripExportStatus.cancelled);
      }
      return const TripExportResult.success();
    } catch (err) {
      debugPrint('Failed to share trip CSV: $err');
      return TripExportResult(TripExportStatus.failed, message: '$err');
    }
  }

  /// Saves a copy of the trip CSV wherever the driver chooses — Downloads, a
  /// Drive folder, anywhere the system file picker can reach.
  ///
  /// On Android and iOS the picker writes the bytes itself; on desktop it only
  /// returns a destination, so the bytes are written here.
  Future<TripExportResult> saveTripCsvCopy(
    String? csvPath, {
    required String exportName,
  }) async {
    final source = await _readableCsv(csvPath);
    if (source == null) return const TripExportResult(TripExportStatus.missingFile);
    try {
      final bytes = await source.readAsBytes();
      final isMobile = Platform.isAndroid || Platform.isIOS;
      final destination = await FilePicker.platform.saveFile(
        dialogTitle: 'Save trip CSV',
        fileName: exportName,
        // Only mobile wants the bytes: the picker writes the file itself there.
        // macOS throws outright when they are supplied, and the desktop branch
        // below does the write.
        bytes: isMobile ? bytes : null,
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (destination == null) {
        return const TripExportResult(TripExportStatus.cancelled);
      }
      // Desktop returns a path without writing anything to it.
      if (!isMobile) {
        await File(destination).writeAsBytes(bytes, flush: true);
      }
      return TripExportResult.success(savedPath: destination);
    } catch (err) {
      debugPrint('Failed to save trip CSV copy: $err');
      return TripExportResult(TripExportStatus.failed, message: '$err');
    }
  }

  /// The trip's CSV, or null when there is nothing on disk to export.
  Future<File?> _readableCsv(String? csvPath) async {
    if (csvPath == null || csvPath.isEmpty) return null;
    final file = File(csvPath);
    if (!await file.exists()) return null;
    if (await file.length() == 0) return null;
    return file;
  }

  /// Copies [source] into a scratch directory under [exportName].
  ///
  /// The directory is emptied first: staged copies are only needed for the
  /// lifetime of one share sheet, and without this they accumulate in the cache
  /// and two trips started in the same minute would collide on the same name.
  Future<File> _stageForExport(File source, String exportName) async {
    final tempDir = await getTemporaryDirectory();
    final stageDir = Directory(p.join(tempDir.path, 'trip_exports'));
    try {
      if (await stageDir.exists()) {
        await stageDir.delete(recursive: true);
      }
    } catch (err) {
      debugPrint('Could not clear the trip export staging directory: $err');
    }
    await stageDir.create(recursive: true);
    final staged = File(p.join(stageDir.path, exportName));
    return source.copy(staged.path);
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
