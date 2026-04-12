import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

import '../constants/obd_pids.dart';

/// Handles Bluetooth OBD-II transport and orchestrates bulk PID polling.
///
/// Strategy:
///   * Establish ELM327 session with a single init script.
///   * Ask the ECU for every "fast" PID in a single mode-01 multi-PID frame
///     (RPM, speed, MAP, MAF, engine load, IAT).
///   * Every 2s, send one bulk "slow" frame for aux telemetry.
///   * If the ECU claims direct fuel rate (PID 015E) we poll it alongside.
///
/// Switching from single-PID polling to one bulk frame drops the per-cycle
/// latency from ~800ms (8 round-trips) to ~120ms (1 round-trip) on typical
/// Bluetooth ELM327 clones.
class ObdService {
  ObdService();

  Obd2Plugin _obd2 = Obd2Plugin();
  Obd2Plugin get obd2 => _obd2;

  Function(String)? onDataReceived;
  void Function()? onDisconnected;

  bool _connected = false;
  bool _listenerReady = false;
  bool _isPolling = false;
  bool _commandInFlight = false;
  bool _fuelRateSupported = false;
  final List<Completer<String?>> _pendingFrameRequests = [];
  Completer<void>? _commandResponseCompleter;
  Completer<void>? _readyCompleter;
  Future<void>? _pollLoopFuture;
  int _pollErrorStreak = 0;
  int _connectAttemptToken = 0;
  DateTime _nextSlowPollAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const int _maxTransientPollErrors = 3;
  static const Duration _slowPollInterval = Duration(seconds: 2);
  static const Duration _bulkResponseTimeout = Duration(milliseconds: 450);
  static const Duration _reconnectSettleDelay = Duration(milliseconds: 350);
  static const int _maxConnectAttempts = 3;

  bool get isConnected => _connected;
  bool get fuelRateSupported => _fuelRateSupported;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    await FlutterBluetoothSerial.instance.requestEnable();
    return await _obd2.getNearbyPairedDevices;
  }

  Future<void> connect(BluetoothDevice device) async {
    await FlutterBluetoothSerial.instance.requestEnable();
    await disconnect(notify: false);
    for (var attempt = 1; attempt <= _maxConnectAttempts; attempt++) {
      try {
        await _connectInternal(device);
        return;
      } on PlatformException catch (err) {
        final isConnectError = err.code == 'connect_error';
        final isLastAttempt = attempt >= _maxConnectAttempts;
        if (!isConnectError || isLastAttempt) rethrow;
        debugPrint(
          'OBD connect_error (attempt $attempt/$_maxConnectAttempts): '
          '${err.message}',
        );
        await _disconnectTransport();
        await Future.delayed(
          Duration(
            milliseconds:
                _reconnectSettleDelay.inMilliseconds * (attempt + 1),
          ),
        );
      }
    }
  }

  Future<void> _connectInternal(BluetoothDevice device) async {
    final attemptToken = ++_connectAttemptToken;
    final readyCompleter = Completer<void>();
    _readyCompleter = readyCompleter;
    unawaited(readyCompleter.future.catchError((_) {}));
    try {
      await _obd2.getConnection(
        device,
        (connection) async {
          if (_connectAttemptToken != attemptToken) return;
          try {
            await _ensureListener();
            await _initObd();
            _connected = true;
            _nextSlowPollAt = DateTime.now().add(_slowPollInterval);
            _pollErrorStreak = 0;
            if (!readyCompleter.isCompleted) {
              readyCompleter.complete();
            }
          } catch (err) {
            if (!readyCompleter.isCompleted) {
              readyCompleter.completeError(err);
            }
          }
        },
        (err) {
          if (_connectAttemptToken != attemptToken) return;
          _markDisconnected();
          if (!readyCompleter.isCompleted) {
            readyCompleter.completeError(err);
          }
        },
      );
    } catch (err) {
      if (_connectAttemptToken == attemptToken && !readyCompleter.isCompleted) {
        readyCompleter.completeError(err);
      }
      rethrow;
    }
    await readyCompleter.future.timeout(const Duration(seconds: 10));
  }

  Future<void> _ensureListener() async {
    if (_listenerReady) return;

    await _obd2.setOnDataReceived((command, response, requestCode) {
      final payload = '$command: $response';
      final pendingResponse = _commandResponseCompleter;
      if (pendingResponse != null && !pendingResponse.isCompleted) {
        pendingResponse.complete();
      }
      if (_pendingFrameRequests.isNotEmpty) {
        final completer = _pendingFrameRequests.removeAt(0);
        if (!completer.isCompleted) {
          completer.complete(payload);
        }
      }
      onDataReceived?.call(payload);
    });

    _listenerReady = true;
  }

  Future<void> _initObd() async {
    final waitMs = await _obd2.configObdWithJSON(obdInitCommands);
    await Future.delayed(Duration(milliseconds: waitMs));
    // Assume fuel-rate support is off until a probe says otherwise; the
    // provider probes it via [probeFuelRateSupport] after first cycle.
    _fuelRateSupported = false;
  }

  Future<bool> startListening(Function(String) onData) async {
    onDataReceived = onData;
    await _ensureListener();
    await _readyCompleter?.future;

    if (!_connected) return false;
    if (_isPolling) return true;
    _isPolling = true;
    _pollLoopFuture = _pollLoop().catchError((_) {});
    return true;
  }

  Future<void> stopListening() async {
    _isPolling = false;
    final pendingLoop = _pollLoopFuture;
    _pollLoopFuture = null;
    try {
      await pendingLoop;
    } catch (_) {}
  }

  Future<void> disconnect({bool notify = true}) async {
    _isPolling = false;
    final pendingLoop = _pollLoopFuture;
    _pollLoopFuture = null;
    try {
      await pendingLoop;
    } catch (_) {}
    await _disconnectTransport();
    _markDisconnected(notify: notify);
    _readyCompleter = null;
  }

  Future<void> _pollLoop() async {
    while (_isPolling && _connected) {
      try {
        await _sendBulkCommand(fastBulkCommand);
        if (!_isPolling || !_connected) break;

        final now = DateTime.now();
        if (!now.isBefore(_nextSlowPollAt)) {
          _nextSlowPollAt = now.add(_slowPollInterval);
          await _sendBulkCommand(slowBulkCommand);
          if (_fuelRateSupported) {
            await _sendBulkCommand(premiumFuelRateCommand);
          }
        }

        _pollErrorStreak = 0;
      } catch (err) {
        if (!_isPolling || !_connected) break;

        _pollErrorStreak += 1;
        debugPrint('OBD poll error ($_pollErrorStreak): $err');

        if (_pollErrorStreak < _maxTransientPollErrors) {
          final retryDelayMs = (200 * _pollErrorStreak).clamp(200, 1000);
          await _delayWhileActive(Duration(milliseconds: retryDelayMs));
          continue;
        }

        _markDisconnected();
        await _disconnectTransport();
        break;
      }
    }
  }

  Future<void> _sendBulkCommand(String command) async {
    await _withCommandLock(() async {
      final responseCompleter = Completer<void>();
      _commandResponseCompleter = responseCompleter;
      try {
        await _obd2.getParamsFromJSON(buildBulkRequestJson(command));
        await responseCompleter.future.timeout(
          _bulkResponseTimeout,
          onTimeout: () {},
        );
      } finally {
        if (identical(_commandResponseCompleter, responseCompleter)) {
          _commandResponseCompleter = null;
        }
      }
    });
  }

  Future<void> _delayWhileActive(Duration total) async {
    var remainingMs = total.inMilliseconds;
    while (remainingMs > 0 && _isPolling && _connected) {
      final stepMs = remainingMs > 100 ? 100 : remainingMs;
      await Future.delayed(Duration(milliseconds: stepMs));
      remainingMs -= stepMs;
    }
  }

  Future<T> _withCommandLock<T>(Future<T> Function() action) async {
    while (_commandInFlight) {
      if (!_connected) {
        throw StateError('OBD connection closed');
      }
      await Future.delayed(const Duration(milliseconds: 8));
    }
    _commandInFlight = true;
    try {
      return await action();
    } finally {
      _commandInFlight = false;
    }
  }

  Future<void> _disconnectTransport() async {
    try {
      await _obd2.disconnect();
    } catch (_) {}
    _listenerReady = false;
    _obd2 = Obd2Plugin();
  }

  void _markDisconnected({bool notify = true}) {
    _connectAttemptToken += 1;
    final wasConnected = _connected;
    _connected = false;
    _isPolling = false;
    _commandInFlight = false;
    _fuelRateSupported = false;
    final pendingResponse = _commandResponseCompleter;
    if (pendingResponse != null && !pendingResponse.isCompleted) {
      pendingResponse.complete();
    }
    _commandResponseCompleter = null;
    _nextSlowPollAt = DateTime.fromMillisecondsSinceEpoch(0);
    _completePendingFrameRequests();
    if (notify && wasConnected) {
      onDisconnected?.call();
    }
  }

  void _completePendingFrameRequests() {
    if (_pendingFrameRequests.isEmpty) return;
    for (final completer in _pendingFrameRequests) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    _pendingFrameRequests.clear();
  }

  /// Calculates instantaneous fuel flow (mL/s) from RPM + MAP + IAT, using
  /// the speed-density formula when MAF is not available.
  double fuelFlow(
    double rpm,
    double mapKpa,
    double iatKelvin, {
    required double volumetricEfficiency,
    required double engineDisplacementLiters,
    double equivRatio = 1.0,
    double? mafGramsPerSec,
  }) {
    if (rpm <= 0) return 0;
    final actualAfr = 14.7 * (equivRatio <= 0 ? 1.0 : equivRatio);

    final gramsOfAir = mafGramsPerSec ??
        _calcGramsOfAir(
          rpm: rpm,
          mapKpa: mapKpa,
          iatKelvin: iatKelvin,
          volumetricEfficiency: volumetricEfficiency,
          engineDisplacementLiters: engineDisplacementLiters,
        );
    final gramsOfFuel = gramsOfAir / actualAfr;
    // 745 g/L is approximate density of petrol; 1000 converts L → mL.
    return (gramsOfFuel / 745) * 1000;
  }

  double _calcGramsOfAir({
    required double rpm,
    required double mapKpa,
    required double iatKelvin,
    required double volumetricEfficiency,
    required double engineDisplacementLiters,
  }) {
    if (iatKelvin <= 0 || mapKpa <= 0) return 0;
    const double molarMassAir = 28.97;
    const double gasConstant = 8.314;
    final imap = (rpm * mapKpa) / (iatKelvin * 2);
    final gramsOfAir = (imap / 60) *
        (volumetricEfficiency / 100) *
        engineDisplacementLiters *
        molarMassAir /
        gasConstant;
    return gramsOfAir;
  }

  /// Marks PID 015E as available so the poll loop will start requesting it.
  void enableFuelRatePid() {
    _fuelRateSupported = true;
  }

  /// Sends mode 03 (stored DTCs) and returns raw response for the provider
  /// to decode into P/B/C/U codes.
  Future<String?> requestDtcRaw({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_connected) return null;
    await _ensureListener();
    await _readyCompleter?.future;
    if (!_connected) return null;
    final completer = Completer<String?>();
    _pendingFrameRequests.add(completer);
    try {
      await _sendBulkCommand('03');
    } catch (_) {
      _pendingFrameRequests.remove(completer);
      return null;
    }
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      _pendingFrameRequests.remove(completer);
    }
  }

  /// Sends mode 04 to clear stored DTCs.
  Future<void> clearDtc() async {
    if (!_connected) return;
    await _sendBulkCommand('04');
  }

  Future<String?> requestSingleFrame({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!_connected) return null;
    await _ensureListener();
    await _readyCompleter?.future;
    if (!_connected) return null;
    final completer = Completer<String?>();
    _pendingFrameRequests.add(completer);
    try {
      await _sendBulkCommand(fastBulkCommand);
    } catch (err) {
      _pendingFrameRequests.remove(completer);
      return null;
    }
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      _pendingFrameRequests.remove(completer);
    }
  }
}
