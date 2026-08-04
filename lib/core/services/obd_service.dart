import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

import '../constants/obd_pids.dart';
import '../utils/pid_support.dart';
import 'storage_service.dart';

/// Handles Bluetooth OBD-II transport and orchestrates bulk PID polling.
///
/// Strategy:
///   * Establish the ELM327 session with a prompt-synchronised init script —
///     every command waits for the adapter's `>` prompt instead of relying on
///     blanket delays.
///   * Probe the ECU's supported-PID bitmasks (01 00 / 01 20 / 01 40) and
///     poll only what the vehicle actually answers.
///   * Each poll cycle sends bulk mode-01 requests (max 6 PIDs each)
///     back-to-back, covering all telemetry PIDs every cycle. Adapters that
///     reject multi-PID requests fall back to one command per PID.
///   * The negotiated protocol is cached per device address so reconnects skip
///     the ELM327 auto-search.
class ObdService {
  ObdService(this._storage);

  final StorageService _storage;

  Obd2Plugin _obd2 = Obd2Plugin();
  Obd2Plugin get obd2 => _obd2;

  PidSupport _pidSupport = PidSupport();

  /// Fires once per complete, prompt-terminated response from the poll loop.
  Function(String)? onDataReceived;
  void Function()? onDisconnected;

  /// Fires once per completed poll cycle, after every command in the cycle has
  /// been delivered to [onDataReceived].
  void Function()? onCycleComplete;

  bool _connected = false;
  bool _listenerReady = false;
  bool _isPolling = false;
  bool _fuelRateSupported = false;
  bool _bulkModeActive = true;
  bool _desynced = false;
  String? _activeProtocol;
  int _lastCycleMillis = 0;
  int _bulkFailureStreak = 0;
  int _consecutiveTimeouts = 0;
  int _pollErrorStreak = 0;
  int _connectAttemptToken = 0;
  int _transportGeneration = 0;
  DateTime? _lastThrottledLog;

  Completer<String>? _pendingResponse;
  Completer<void>? _readyCompleter;
  Future<void>? _pollLoopFuture;
  Future<void> _commandLock = Future<void>.value();
  List<String> _pollCommands = const [];

  static const int _maxTransientPollErrors = 3;
  static const int _maxBulkFailures = 2;
  static const int _maxConnectAttempts = 3;
  static const Duration _commandTimeout = Duration(milliseconds: 600);
  static const Duration _interCycleDelay = Duration.zero;
  static const Duration _idleCycleDelay = Duration(milliseconds: 200);
  static const Duration _reconnectSettleDelay = Duration(milliseconds: 350);
  static const Duration _atTimeout = Duration(seconds: 1);
  static const Duration _resetTimeout = Duration(seconds: 5);
  static const Duration _warmStartTimeout = Duration(seconds: 2);
  static const Duration _protocolTimeout = Duration(seconds: 2);
  static const Duration _pidProbeTimeout = Duration(seconds: 5);
  static const String _protocolCachePrefix = 'obd_protocol_';

  static final RegExp _protocolDigit = RegExp(r'[0-9A-Ca-c]');

  bool get isConnected => _connected;
  bool get fuelRateSupported => _fuelRateSupported;

  /// Canonical PID keys the ECU reported as supported, empty until the
  /// bitmask probes have run.
  Set<String> get supportedPids => _pidSupport.supportedPids;

  /// False once the adapter has rejected enough multi-PID requests that we
  /// permanently fell back to one command per PID for this session.
  bool get bulkModeActive => _bulkModeActive;

  /// Protocol digit reported by `AT DPN` (e.g. `'6'`), or null if unknown.
  String? get activeProtocol => _activeProtocol;

  /// Wall time in milliseconds of the last completed poll cycle.
  int get lastCycleMillis => _lastCycleMillis;

  /// Bonded devices only — an inquiry scan costs ~12 s and adds nothing for
  /// an adapter the user already paired.
  Future<List<BluetoothDevice>> getPairedDevices() async {
    await FlutterBluetoothSerial.instance.requestEnable();
    return await _obd2.getPairedDevices;
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
            await _initObd(device);
            _connected = true;
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
    // Backstop only: every init command carries its own timeout, so this just
    // guards against getConnection itself hanging. The worst-case prompt-synced
    // init (including one cached-protocol retry) has to fit inside it.
    await readyCompleter.future.timeout(const Duration(seconds: 30));
  }

  Future<void> _ensureListener() async {
    if (_listenerReady) return;
    // The plugin attaches its input listener to `connection`, and refuses a
    // second registration — registering before the socket exists would leave
    // us permanently deaf.
    if (_obd2.connection == null) return;

    await _obd2.setOnDataReceived((command, response, requestCode) {
      _handleTransportPayload('$command: $response');
    });

    _listenerReady = true;
  }

  /// Single delivery point for adapter responses.
  ///
  /// The plugin buffers bytes until the ELM327 `>` prompt, so exactly one call
  /// arrives per complete response. It only ever completes the pending
  /// [_sendCommand] completer — telemetry is handed to [onDataReceived] from
  /// the poll loop so there is exactly one delivery path.
  void _handleTransportPayload(String payload) {
    if (_desynced) {
      _desynced = false;
      _logThrottled('resync: discarded late response "$payload"');
      return;
    }
    final pending = _pendingResponse;
    if (pending == null || pending.isCompleted) {
      _logThrottled('dropped unsolicited response "$payload"');
      return;
    }
    _pendingResponse = null;
    _consecutiveTimeouts = 0;
    pending.complete(payload);
  }

  /// Runs the prompt-synchronised ELM327 init script.
  ///
  /// When a protocol was cached for this device we warm-start and select it
  /// directly; if the ECU then fails to answer `01 00` the cache is dropped and
  /// the whole sequence is retried once with `AT Z` + `AT SP 0`.
  Future<void> _initObd(BluetoothDevice device, {bool useCache = true}) async {
    final cacheKey = '$_protocolCachePrefix${device.address}';
    _pidSupport = PidSupport();
    _fuelRateSupported = false;
    _bulkModeActive = true;
    _bulkFailureStreak = 0;
    _pollCommands = const [];
    _activeProtocol = null;

    String? cachedProtocol;
    if (useCache) {
      try {
        final stored = await _storage.getSetting(cacheKey);
        if (stored != null && stored.isNotEmpty) cachedProtocol = stored;
      } catch (err) {
        _log('protocol cache read failed: $err');
      }
    }

    // 1. Reset (cold) or warm-start (cached protocol).
    if (cachedProtocol != null) {
      _activeProtocol = cachedProtocol;
      await _sendCommand('AT WS', timeout: _warmStartTimeout);
    } else {
      await _sendCommand('AT Z', timeout: _resetTimeout);
    }

    // 2. Echo / linefeeds / spaces / headers off.
    for (final command in obdInitPrologue) {
      await _sendCommand(command, timeout: _atTimeout);
    }

    // 3. Protocol selection.
    await _sendCommand(
      cachedProtocol != null ? 'AT SP $cachedProtocol' : 'AT SP 0',
      timeout: _protocolTimeout,
    );

    // 4. Adaptive timing + per-request timeout.
    for (final command in obdInitEpilogue) {
      await _sendCommand(command, timeout: _atTimeout);
    }

    // 5. First bitmask probe — the ELM327 auto-search actually happens here,
    //    which is why it gets the long timeout.
    final firstProbe = await _sendCommand(
      pidSupportProbes.first,
      timeout: _pidProbeTimeout,
    );
    if (!_isPositiveResponse(firstProbe)) {
      if (cachedProtocol != null) {
        _log('cached protocol "$cachedProtocol" rejected — retrying auto');
        try {
          await _storage.removeSetting(cacheKey);
        } catch (err) {
          _log('protocol cache clear failed: $err');
        }
        await _initObd(device, useCache: false);
        return;
      }
      throw StateError('ECU did not respond to 01 00');
    }
    _pidSupport.parseRawResponse(_stripCommandPrefix(firstProbe));

    // 6. Remaining ranges, but only when the previous bitmask advertises them.
    for (var i = 1; i < pidSupportProbes.length; i++) {
      final rangeStart = (i - 1) * 0x20;
      if (!_pidSupport.hasNextRange(rangeStart)) break;
      final response = await _sendCommand(
        pidSupportProbes[i],
        timeout: _atTimeout,
      );
      if (!_isPositiveResponse(response)) break;
      _pidSupport.parseRawResponse(_stripCommandPrefix(response));
    }

    // 7. Cache the negotiated protocol so the next connect skips the search.
    final dpnResponse = await _sendCommand('AT DPN', timeout: _atTimeout);
    final protocol = _parseProtocolDigit(dpnResponse);
    if (protocol != null) {
      _activeProtocol = protocol;
      try {
        await _storage.setSetting(cacheKey, protocol);
      } catch (err) {
        _log('protocol cache write failed: $err');
      }
    }

    // 8. Direct fuel rate replaces the MAF / speed-density estimate.
    _fuelRateSupported = _pidSupport.isSupported(fuelRatePidKey);
    _rebuildPollCommands();
    _log(
      'init complete — protocol=${_activeProtocol ?? '?'} '
      'pids=${_pidSupport.supportedPids.length} commands=$_pollCommands',
    );
  }

  Future<bool> startListening(Function(String) onData) async {
    onDataReceived = onData;
    await _ensureListener();
    await _readyCompleter?.future;

    if (!_connected) return false;
    if (_isPolling) return true;
    _isPolling = true;
    _pollErrorStreak = 0;
    _bulkFailureStreak = 0;
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
    final cycleWatch = Stopwatch();
    while (_isPolling && _connected) {
      try {
        if (_pollCommands.isEmpty) {
          await _delayWhileActive(_idleCycleDelay);
          continue;
        }

        cycleWatch
          ..reset()
          ..start();
        for (final command in _pollCommands) {
          final response = await _sendCommand(command);
          if (_isNegativeResponse(response)) {
            _registerBulkFailure(command, response);
          } else {
            _bulkFailureStreak = 0;
            onDataReceived?.call(response);
          }
          if (!_isPolling || !_connected) break;
        }
        cycleWatch.stop();
        _lastCycleMillis = cycleWatch.elapsedMilliseconds;

        onCycleComplete?.call();
        _pollErrorStreak = 0;
        await _delayWhileActive(_interCycleDelay);
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

  /// Counts consecutive rejected poll commands and permanently drops to
  /// single-PID requests once the adapter has clearly refused bulk mode.
  void _registerBulkFailure(String command, String response) {
    _bulkFailureStreak += 1;
    _logThrottled(
      'negative response for "$command": "$response" '
      '(streak $_bulkFailureStreak)',
    );
    if (!_bulkModeActive || _bulkFailureStreak < _maxBulkFailures) return;
    _bulkModeActive = false;
    _bulkFailureStreak = 0;
    _rebuildPollCommands();
    _log('bulk multi-PID rejected — falling back to single-PID requests');
  }

  /// Writes [command] to the adapter and waits for its prompt-terminated
  /// response. This is the only place that talks to the transport.
  ///
  /// Returns `''` on timeout, which also arms a one-shot resync so a late
  /// response can never complete the next command's completer.
  Future<String> _sendCommand(String command, {Duration? timeout}) {
    return _withCommandLock(() async {
      final conn = _obd2.connection;
      if (conn == null || !conn.isConnected) {
        throw StateError('OBD Bluetooth connection lost');
      }
      final completer = Completer<String>();
      _pendingResponse = completer;
      try {
        // ELM327 terminates on CR; a trailing LF is echoed back as noise.
        conn.output.add(Uint8List.fromList(utf8.encode('$command\r')));
        await conn.output.allSent;
        return await completer.future.timeout(
          timeout ?? _commandTimeout,
          onTimeout: () {
            _onCommandTimeout(command);
            return '';
          },
        );
      } finally {
        if (identical(_pendingResponse, completer)) {
          _pendingResponse = null;
        }
      }
    });
  }

  void _onCommandTimeout(String command) {
    _consecutiveTimeouts += 1;
    _logThrottled('command "$command" timed out ($_consecutiveTimeouts)');
    // Arm the discard only on the first timeout after a healthy exchange. If
    // the adapter has genuinely gone quiet, discarding every later response
    // would keep us permanently one response behind instead of recovering.
    _desynced = _consecutiveTimeouts == 1;
  }

  Future<void> _delayWhileActive(Duration total) async {
    var remainingMs = total.inMilliseconds;
    while (remainingMs > 0 && _isPolling && _connected) {
      final stepMs = remainingMs > 100 ? 100 : remainingMs;
      await Future.delayed(Duration(milliseconds: stepMs));
      remainingMs -= stepMs;
    }
  }

  /// Serialises transport access through a future chain — no busy-waiting.
  Future<T> _withCommandLock<T>(Future<T> Function() action) {
    final generation = _transportGeneration;
    final next = _commandLock.then<T>((_) {
      final conn = _obd2.connection;
      if (generation != _transportGeneration ||
          conn == null ||
          !conn.isConnected) {
        throw StateError('OBD connection closed');
      }
      return action();
    });
    _commandLock = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _disconnectTransport() async {
    _transportGeneration += 1;
    _completePendingResponse();
    try {
      await _obd2.disconnect();
    } catch (err) {
      _log('transport disconnect failed: $err');
    }
    _listenerReady = false;
    _desynced = false;
    _consecutiveTimeouts = 0;
    // A fresh instance is mandatory: the plugin refuses a second
    // setOnDataReceived and getConnection would reuse the stale connection.
    _obd2 = Obd2Plugin();
  }

  void _markDisconnected({bool notify = true}) {
    _connectAttemptToken += 1;
    final wasConnected = _connected;
    _connected = false;
    _isPolling = false;
    _fuelRateSupported = false;
    _pollCommands = const [];
    _completePendingResponse();
    if (notify && wasConnected) {
      onDisconnected?.call();
    }
  }

  void _completePendingResponse() {
    final pending = _pendingResponse;
    _pendingResponse = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete('');
    }
  }

  /// Recomputes the per-cycle command list from the supported-PID bitmask.
  void _rebuildPollCommands() {
    final desired = _desiredPollPids();
    _pollCommands = _bulkModeActive
        ? _pidSupport.buildBulkCommands(desired)
        : _pidSupport.buildSingleCommands(desired);
  }

  /// [pollPidKeys] filtered by the ECU bitmask, with [essentialPidKeys] unioned
  /// back in so a partial or bogus bitmask can never strip RPM / speed / MAP /
  /// MAF. Ordering always follows [pollPidKeys].
  List<String> _desiredPollPids() {
    final desired = <String>[];
    if (_pidSupport.parsed) {
      final supported = _pidSupport.filter(pollPidKeys).toSet();
      for (final pid in pollPidKeys) {
        if (supported.contains(pid) || essentialPidKeys.contains(pid)) {
          desired.add(pid);
        }
      }
    } else {
      desired.addAll(pollPidKeys);
    }
    if (_fuelRateSupported && !desired.contains(fuelRatePidKey)) {
      desired.add(fuelRatePidKey);
    }
    return desired;
  }

  String _stripCommandPrefix(String payload) {
    final colonIndex = payload.indexOf(':');
    return colonIndex >= 0 ? payload.substring(colonIndex + 1) : payload;
  }

  /// `AT DPN` answers with the protocol digit, optionally prefixed by `A` when
  /// the protocol was auto-detected (e.g. `A6`). We keep the last hex digit.
  String? _parseProtocolDigit(String response) {
    final payload = _stripCommandPrefix(response).trim();
    for (var i = payload.length - 1; i >= 0; i--) {
      final char = payload[i];
      if (_protocolDigit.hasMatch(char)) return char.toUpperCase();
    }
    return null;
  }

  bool _isPositiveResponse(String response) {
    if (response.isEmpty) return false;
    return response.toUpperCase().replaceAll(' ', '').contains('41');
  }

  bool _isNegativeResponse(String response) {
    if (response.isEmpty) return true;
    final normalized = response.toUpperCase().replaceAll(' ', '');
    if (normalized.contains('?') ||
        normalized.contains('NODATA') ||
        normalized.contains('STOPPED') ||
        normalized.contains('UNABLETOCONNECT') ||
        normalized.contains('BUSERROR') ||
        normalized.contains('CANERROR')) {
      return true;
    }
    return !normalized.contains('41');
  }

  void _log(String message) {
    if (!kDebugMode) return;
    debugPrint('[OBD] $message');
  }

  void _logThrottled(String message) {
    if (!kDebugMode) return;
    final now = DateTime.now();
    final last = _lastThrottledLog;
    if (last != null && now.difference(last).inMilliseconds < 500) return;
    _lastThrottledLog = now;
    debugPrint('[OBD] $message');
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
    if (_fuelRateSupported) return;
    _fuelRateSupported = true;
    _rebuildPollCommands();
  }

  /// Requests a single RPM frame as a connectivity check. Safe to call while
  /// polling — the command mutex serialises it against the poll loop.
  Future<String?> requestSingleFrame({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!_connected) return null;
    await _readyCompleter?.future;
    if (!_connected) return null;
    try {
      final response = await _sendCommand('01 0C', timeout: timeout);
      return response.isEmpty ? null : response;
    } catch (err) {
      _log('single frame request failed: $err');
      return null;
    }
  }
}
