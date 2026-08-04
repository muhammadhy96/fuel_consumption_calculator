# Fuel Trip Tracker

Fuel Trip Tracker is a Flutter app for live OBD-II fuel monitoring, trip logging, and per-vehicle profile management. It targets Android, iOS, desktop, and web from a single codebase.

## Features

- Pair with ELM327-compatible Bluetooth adapters
- Stream live OBD-II telemetry with dashboard gauges
- Estimate and smooth fuel flow in real time
- Save trip sessions locally and inspect detailed charts
- Manage multiple vehicle profiles with fuel type and calibration data
- Read and clear DTC trouble codes

## Production Defaults

- Android application id: `dev.muham.fueltriptracker`
- iOS bundle id: `dev.muham.fueltriptracker`
- macOS bundle id: `dev.muham.fueltriptracker`
- Windows binary name: `fuel_trip_tracker`
- Visible app name: `Fuel Trip Tracker`

## Android Release Signing

1. Copy `android/key.properties.example` to `android/key.properties`.
2. Update the file with the path to your release keystore and its passwords.
3. Place the keystore outside version control.

Example:

```properties
storeFile=C:\\keys\\fuel-trip-tracker.jks
storePassword=your-store-password
keyAlias=upload
keyPassword=your-key-password
```

## Build Commands

```bash
flutter pub get
flutter analyze
flutter test
flutter build appbundle --release
flutter build ipa --release
flutter build windows --release
flutter build web --release
```

## Notes

- iOS and macOS still require valid Apple signing configured in Xcode.
- Android release builds now expect a real signing setup instead of template debug signing.
- Trip data is stored locally and exported as CSV files.
