import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/file_service.dart';
import '../../models/trip.dart';
import '../../state/trip_provider.dart';

/// App-bar actions for getting a trip's CSV off the device: share it, or save a
/// copy wherever the driver chooses.
///
/// Trips are recorded into the app's private storage, which nothing else on the
/// phone can read — these two actions are the only way the data leaves.
class TripExportActions extends StatelessWidget {
  const TripExportActions({
    super.key,
    required this.trip,
    required this.profileName,
  });

  final Trip trip;
  final String profileName;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Builder(
          builder: (buttonContext) => IconButton(
            tooltip: 'Share trip CSV',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _share(buttonContext),
          ),
        ),
        IconButton(
          tooltip: 'Save a copy',
          icon: const Icon(Icons.save_alt),
          onPressed: () => _saveCopy(context),
        ),
      ],
    );
  }

  Future<void> _share(BuildContext context) async {
    final trips = context.read<TripProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await trips.shareTrip(
      trip,
      profileName,
      // Required on iPad, where the share sheet is a popover anchored to the
      // widget that opened it.
      sharePositionOrigin: _originOf(context),
    );
    _report(messenger, result, verb: 'share', shared: true);
  }

  Future<void> _saveCopy(BuildContext context) async {
    final trips = context.read<TripProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await trips.saveTripCopy(trip, profileName);
    _report(messenger, result, verb: 'save', shared: false);
  }

  /// Screen rectangle of the button that was tapped, when it can be resolved.
  Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _report(
    ScaffoldMessengerState messenger,
    TripExportResult result, {
    required String verb,
    required bool shared,
  }) {
    switch (result.status) {
      case TripExportStatus.success:
        final saved = result.savedPath;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              shared
                  ? 'Trip CSV shared.'
                  : saved == null
                      ? 'Trip CSV saved.'
                      : 'Saved ${_fileNameOf(saved)}',
            ),
          ),
        );
      case TripExportStatus.cancelled:
        // The driver backed out; the share sheet or save dialog said so already.
        break;
      case TripExportStatus.missingFile:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No CSV was recorded for this trip.'),
          ),
        );
      case TripExportStatus.failed:
        messenger.showSnackBar(
          SnackBar(content: Text('Could not $verb the trip CSV.')),
        );
    }
  }

  String _fileNameOf(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }
}
