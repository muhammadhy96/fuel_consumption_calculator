String formatDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String formatDuration(int seconds) {
  final duration = Duration(seconds: seconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final secs = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours}h ${minutes}m';
  }
  return '${minutes}m ${secs}s';
}

String formatFuel(double ml) => '${(ml / 1000).toStringAsFixed(2)} L';

String formatTimestamp(DateTime timestamp) {
  final hours = timestamp.hour.toString().padLeft(2, '0');
  final minutes = timestamp.minute.toString().padLeft(2, '0');
  final seconds = timestamp.second.toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
