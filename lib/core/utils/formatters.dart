String formatDate(DateTime date) {
  final months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

String formatDuration(int seconds) {
  final duration = Duration(seconds: seconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final secs = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours}h ${minutes}m';
  }
  if (minutes > 0) {
    return '${minutes}m ${secs}s';
  }
  return '${secs}s';
}

String formatFuel(double ml) {
  final liters = ml / 1000;
  if (liters >= 100) return '${liters.toStringAsFixed(0)} L';
  if (liters >= 10) return '${liters.toStringAsFixed(1)} L';
  return '${liters.toStringAsFixed(2)} L';
}

String formatTimestamp(DateTime timestamp) {
  final hours = timestamp.hour.toString().padLeft(2, '0');
  final minutes = timestamp.minute.toString().padLeft(2, '0');
  final seconds = timestamp.second.toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String formatDistance(double km) {
  if (km >= 100) return '${km.toStringAsFixed(0)} km';
  if (km >= 10) return '${km.toStringAsFixed(1)} km';
  return '${km.toStringAsFixed(2)} km';
}

String formatConsumption(double litersPer100Km) {
  if (litersPer100Km <= 0 || !litersPer100Km.isFinite) return '--';
  if (litersPer100Km >= 100) return '${litersPer100Km.toStringAsFixed(0)} L/100km';
  if (litersPer100Km >= 10) return '${litersPer100Km.toStringAsFixed(1)} L/100km';
  return '${litersPer100Km.toStringAsFixed(2)} L/100km';
}

String formatSpeed(double kmh) => '${kmh.toStringAsFixed(0)} km/h';

String formatRpm(double rpm) {
  if (rpm >= 1000) return '${(rpm / 1000).toStringAsFixed(1)}k';
  return rpm.toStringAsFixed(0);
}
