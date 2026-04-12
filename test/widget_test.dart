import 'package:flutter_test/flutter_test.dart';

import 'package:fuel_consumption_calculator/core/utils/formatters.dart';

void main() {
  test('formatDuration renders hours and minutes when above one hour', () {
    expect(formatDuration(3665), '1h 1m');
  });

  test('formatFuel converts milliliters to liters', () {
    expect(formatFuel(1250), '1.25 L');
  });

  test('formatConsumption hides non-positive values', () {
    expect(formatConsumption(0), '--');
    expect(formatConsumption(6.789), '6.79 L/100km');
  });
}
