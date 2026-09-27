import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:obd2_plugin/obd2_plugin.dart';

import '../constants/obd_pids.dart';
import '../utils/obd_frame_decoder.dart';
import '../utils/pid_support.dart';
import 'obd_transport.dart';
import 'storage_service.dart';

/// Drives an ELM327 over a Bluetooth or Wi-Fi [ObdTransport] and orchestrates
/// bulk PID polling.
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
///   * The negotiated protocol is cached per adapter so reconnects skip
///     the ELM327 auto-search.
class ObdService {
  ObdService(this._storage);

  final StorageService _storage;

  ObdTransport? _transport;

  PidSupport _pidSupport = PidSupport();

  /// Fires once per complete, prompt-terminated response from the poll loop.
  Function(String)? onDataReceived;
  void Function()? onDisconnected;

  /// Fires once per completed poll cycle, after every command in the cycle has
  /// been delivered to [onDataReceived].
  void Function()? onCycleComplete;

  bool _connected = false;
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

  /// PID keys requested by each entry of [_pollCommands], index for index.
  List<List<String>> _pollCommandPids = const [];

  static const ObdFrameDecoder _decoder = ObdFrameDecoder();

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

  /// No reply at all from the adapter for this long means it has hung while
  /// the link stays up; the link is then dropped so the reconnect
  /// path can recover it. NO DATA / CAN ERROR replies (ECU off) do not count:
  /// the adapter is alive and polling resumes by itself when the ECU returns.
  static const Duration _maxAdapterSilence = Duration(seconds: 10);
  static const String _protocolCachePrefix = 'obd_protocol_';
  static const String _wifiHostKey = 'obd_wifi_host';
  static const String _wifiPortKey = 'obd_wifi_port';

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
    return await Obd2Plugin().getPairedDevices;
  }

  /// The Wi-Fi adapter address used last, or the ELM327 factory default.
  Future<ObdDevice> lastWifiDevice() async {
    String? host;
    int? port;
    try {
      host = await _storage.getSetting(_wifiHostKey);
      port = int.tryParse(await _storage.getSetting(_wifiPortKey) ?? '');
    } catch (err) {
      _log('wifi address read failed: $err');
    }
    return ObdDevice.wifi(
      host: host == null || host.isEmpty ? ObdDevice.defaultWifiHost : host,
      port: port ?? ObdDevice.defaultWifiPort,
    );
  }

  Future<void> _rememberWifiDevice(ObdDevice device) async {
    try {
      await _storage.setSetting(_wifiHostKey, device.address);
      await _storage.setSetting(_wifiPortKey, '${device.port}');
    } catch (err) {
      _log('wifi address write failed: $err');
    }
  }

  Future<void> connect(ObdDevice device) async {
    await disconnect(notify: false);
    for (var attempt = 1; attempt <= _maxConnectAttempts; attempt++) {
      final transport = device.createTransport();
      try {
        await _connectInternal(device, transport);
        if (device.type == ObdConnectionType.wifi) {
          await _rememberWifiDevice(device);
        }
        return;
      } on _TransportOpenError catch (wrapped) {
        final isLastAttempt = attempt >= _maxConnectAttempts;
        if (!transport.isRetryableOpenError(wrapped.cause) || isLastAttempt) {
          Error.throwWithStackTrace(wrapped.cause, wrapped.stackTrace);
        }
        debugPrint(
          'OBD open failed (attempt $attempt/$_maxConnectAttempts): '
          '${wrapped.cause}',
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

  Future<void> _connectInternal(
    ObdDevice device,
    ObdTransport transport,
  ) async {
    final attemptToken = ++_connectAttemptToken;
    final readyCompleter = Completer<void>();
    _readyCompleter = readyCompleter;
    unawaited(readyCompleter.future.catchError((_) {}));
    try {
      _transport = transport;
      try {
        await transport
            .open(onPayload: _handleTransportPayload)
            .timeout(const Duration(seconds: 15));
      } catch (err, stack) {
        throw _TransportOpenError(err, stack);
      }
      if (_connectAttemptToken != attemptToken) return;
      await _initObd(device);
      _connected = true;
      _pollErrorStreak = 0;
      if (!readyCompleter.isCompleted) readyCompleter.complete();
    } catch (err) {
      if (!readyCompleter.isCompleted) {
        readyCompleter.completeError(
          err is _TransportOpenError ? err.cause : err,
        );
      }
      rethrow;
    }
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
  Future<void> _initObd(ObdDevice device, {bool useCache = true}) async {
    final cacheKey = '$_protocolCachePrefix${device.id}';
    _pidSupport = PidSupport();
    _fuelRateSupported = false;
    _bulkModeActive = true;
    _bulkFailureStreak = 0;
    _pollCommands = const [];
    _pollCommandPids = const [];
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

    // 8. Multi-PID requests are only defined for CAN. K-line and J1850 ECUs
    //    answer the first PID of a bulk request and drop the rest.
    if (!_isCanProtocol(_activeProtocol)) _bulkModeActive = false;

    // 9. Direct fuel rate replaces the MAF / speed-density estimate.
    _fuelRateSupported = _pidSupport.isSupported(fuelRatePidKey);
    _rebuildPollCommands();
    _log(
      'init complete — protocol=${_activeProtocol ?? '?'} '
      'pids=${_pidSupport.supportedPids.length} commands=$_pollCommands',
    );
  }

  Future<bool> startListening(Function(String) onData) async {
    onDataReceived = onData;
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
    final adapterSilence = Stopwatch()..start();
    while (_isPolling && _connected) {
      try {
        if (_pollCommands.isEmpty) {
          await _delayWhileActive(_idleCycleDelay);
          continue;
        }

        cycleWatch
          ..reset()
          ..start();
        // Captured once: a bulk-mode fallback rebuilds both lists mid-cycle.
        final commands = _pollCommands;
        final commandPids = _pollCommandPids;
        for (var c = 0; c < commands.length; c++) {
          final command = commands[c];
          final response = await _sendCommand(command);
          if (response.isNotEmpty) adapterSilence.reset();
          if (_isNegativeResponse(response)) {
            _registerBulkFailure(command, response);
          } else {
            if (c < commandPids.length &&
                _isPartialBulkReply(commandPids[c], response)) {
              _registerBulkFailure(command, 'partial reply "$response"');
            } else {
              _bulkFailureStreak = 0;
            }
            onDataReceived?.call(response);
          }
          if (!_isPolling || !_connected) break;
        }
        cycleWatch.stop();
        _lastCycleMillis = cycleWatch.elapsedMilliseconds;

        onCycleComplete?.call();
        _pollErrorStreak = 0;
        if (adapterSilence.elapsed > _maxAdapterSilence) {
          _log('adapter silent for ${adapterSilence.elapsed.inSeconds} s — '
              'dropping the link so it can be re-established');
          _markDisconnected();
          await _disconnectTransport();
          break;
        }
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

  /// True when a positive reply to a multi-PID request is missing an essential
  /// PID the ECU should have answered, the signature of an ECU that only
  /// answers the first PID of a bulk request.
  bool _isPartialBulkReply(List<String> requested, String response) {
    if (requested.length < 2) return false;
    final expected = [
      for (final pid in requested)
        if (essentialPidKeys.contains(pid) && _expectsPid(pid)) pid,
    ];
    if (expected.isEmpty) return false;
    final answered = _decoder.decode(response).values;
    return expected.any((pid) => !answered.containsKey(pid));
  }

  /// Whether the ECU should answer [pid]: per its bitmask when one was parsed,
  /// otherwise only for RPM and speed, which every OBD-II car supports.
  bool _expectsPid(String pid) => _pidSupport.parsed
      ? _pidSupport.isSupported(pid)
      : pid == '010C' || pid == '010D';

  /// ELM327 protocols 1-5 are SAE J1850 and ISO 9141 / 14230 (K-line); 6-C
  /// are CAN. An unknown protocol keeps bulk mode, and a partial reply then
  /// turns it off.
  static bool _isCanProtocol(String? protocol) {
    if (protocol == null) return true;
    return !const {'1', '2', '3', '4', '5'}.contains(protocol);
  }

  /// Writes [command] to the adapter and waits for its prompt-terminated
  /// response. This is the only place that talks to the transport.
  ///
  /// Returns `''` on timeout, which also arms a one-shot resync so a late
  /// response can never complete the next command's completer.
  Future<String> _sendCommand(String command, {Duration? timeout}) {
    return _withCommandLock(() async {
      final transport = _transport;
      if (transport == null || !transport.isConnected) {
        throw StateError('OBD connection lost');
      }
      final completer = Completer<String>();
      _pendingResponse = completer;
      try {
        await transport.write(command);
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
      final transport = _transport;
      if (generation != _transportGeneration ||
          transport == null ||
          !transport.isConnected) {
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
    final transport = _transport;
    _transport = null;
    try {
      await transport?.close();
    } catch (err) {
      _log('transport disconnect failed: $err');
    }
    _desynced = false;
    _consecutiveTimeouts = 0;
  }

  void _markDisconnected({bool notify = true}) {
    _connectAttemptToken += 1;
    final wasConnected = _connected;
    _connected = false;
    _isPolling = false;
    _fuelRateSupported = false;
    _pollCommands = const [];
    _pollCommandPids = const [];
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
    final groupSize = _bulkModeActive ? maxPidsPerBulkRequest : 1;
    final groups = <List<String>>[
      for (var start = 0; start < desired.length; start += groupSize)
        desired.sublist(
          start,
          start + groupSize < desired.length
              ? start + groupSize
              : desired.length,
        ),
    ];
    _pollCommandPids = groups;
    _pollCommands = [
      for (final group in groups) ..._pidSupport.buildBulkCommands(group),
    ];
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

  /// Calculates instantaneous fuel flow (mL/s) from MAF, or from RPM + MAP +
  /// IAT via speed-density when MAF is not available.
  ///
  /// The ECU's closed-loop fuel trims ([stftPercent] + [ltftPercent]) scale
  /// the open-loop fuel mass, following Applied Sciences 16, 5879:
  ///   m_fuel = (m_air / AFR) * (1 + (STFT + LTFT) / 100)
  double fuelFlow(
    double rpm,
    double mapKpa,
    double iatKelvin, {
    required double volumetricEfficiency,
    required double engineDisplacementLiters,
    String fuelType = 'Petrol',
    double equivRatio = 1.0,
    double? mafGramsPerSec,
    double stftPercent = 0,
    double ltftPercent = 0,
  }) {
    if (rpm <= 0) return 0;
    final isDiesel = fuelType.toLowerCase() == 'diesel';
    final stoichAfr = isDiesel ? 14.5 : 14.7;
    final densityGramsPerLiter = isDiesel ? 832.0 : 745.0;
    // Out-of-range λ means the PID is unsupported or the frame was garbage.
    final lambda = equivRatio >= 0.5 && equivRatio <= 10 ? equivRatio : 1.0;
    final actualAfr = stoichAfr * lambda;

    final gramsOfAir = mafGramsPerSec ??
        _calcGramsOfAir(
          rpm: rpm,
          mapKpa: mapKpa,
          iatKelvin: iatKelvin,
          volumetricEfficiency: volumetricEfficiency,
          engineDisplacementLiters: engineDisplacementLiters,
        );
    final gramsOfFuel =
        gramsOfAir / actualAfr * fuelTrimFactor(stftPercent, ltftPercent);
    return (gramsOfFuel / densityGramsPerLiter) * 1000;
  }

  /// Air mass flow (g/s) implied by PID 0143. SAE J1979 defines absolute load
  /// as air mass per intake stroke / (1.184 g/L * cylinder displacement), and
  /// a four-stroke engine takes displacement worth of strokes every 2 revs:
  ///   m_air = LOAD_ABS/100 * 1.184 * displacement * RPM / 120
  static double airFromAbsoluteLoad({
    required double absoluteLoadPercent,
    required double rpm,
    required double engineDisplacementLiters,
  }) {
    if (absoluteLoadPercent <= 0 || rpm <= 0) return 0;
    return absoluteLoadPercent / 100 *
        1.184 *
        engineDisplacementLiters *
        rpm /
        120;
  }

  /// Multiplier (1 + (STFT + LTFT) / 100). Non-finite trims count as 0 and the
  /// combined trim is clamped to ±50 %, well past any healthy ECU's limits,
  /// so a garbage frame cannot blow up the estimate.
  static double fuelTrimFactor(double stftPercent, double ltftPercent) {
    final stft = stftPercent.isFinite ? stftPercent : 0.0;
    final ltft = ltftPercent.isFinite ? ltftPercent : 0.0;
    return 1 + (stft + ltft).clamp(-50.0, 50.0) / 100;
  }

  /// Engine speed below which an engine is idling or about to, and the ECU
  /// keeps injecting fuel so it does not stall.
  static const double fuelCutMinRpm = 1200;

  /// Detects deceleration fuel cut-off: the car is moving in gear above idle
  /// with the throttle closed, and the injectors are off. Air keeps flowing,
  /// so the air-based estimate would otherwise count fuel that is not burned.
  ///
  /// [closedThrottlePercent] is the throttle reading learned at idle; a
  /// commanded lambda of exactly 0 is the ECU itself reporting the cut.
  /// PID 0103 bank-1 values (SAE J1979).
  static const int fuelSystemClosedLoop = 0x02;
  static const int fuelSystemOpenLoopLoadOrCut = 0x04;
  static const int fuelSystemClosedLoopFault = 0x10;

  static bool isOverrunFuelCut({
    required double rpm,
    required double speedKph,
    required bool isDiesel,
    double? throttlePercent,
    double? closedThrottlePercent,
    double? mapKpa,
    double? baroKpa,
    double? lambda,
    int? fuelSystemStatus,
  }) {
    if (rpm <= 0) return false;
    if (lambda == 0) return true;
    // PID 0103 is the ECU's own report of its fuelling mode, so it wins over
    // every inference below whenever the car supplies a recognised value.
    switch (fuelSystemStatus) {
      case fuelSystemClosedLoop:
      case fuelSystemClosedLoopFault:
        return false;
      case fuelSystemOpenLoopLoadOrCut:
        // 0x04 covers both deceleration fuel cut and power enrichment; only
        // a throttle that is clearly open makes it enrichment. A car that is
        // standing still cannot be on overrun.
        if (speedKph < 10) return false;
        if (throttlePercent != null && closedThrottlePercent != null) {
          return throttlePercent <= closedThrottlePercent + 1.5;
        }
        if (!isDiesel && mapKpa != null && mapKpa > 0) {
          final baro = baroKpa != null && baroKpa > 0 ? baroKpa : 101.3;
          return mapKpa < 0.7 * baro;
        }
        return rpm >= fuelCutMinRpm;
    }
    if (rpm < fuelCutMinRpm || speedKph < 10) return false;
    if (throttlePercent != null && closedThrottlePercent != null) {
      return throttlePercent <= closedThrottlePercent + 1.5;
    }
    // Without a throttle reading, a deep manifold vacuum above idle means the
    // throttle is shut. Diesels have no throttle, so this says nothing there.
    if (!isDiesel && mapKpa != null && mapKpa > 0) {
      final baro = baroKpa != null && baroKpa > 0 ? baroKpa : 101.3;
      return mapKpa < 0.3 * baro;
    }
    return false;
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

/// Marks a failure of [ObdTransport.open] so [ObdService.connect] retries only
/// link-level errors, never an init script the ECU rejected.
class _TransportOpenError {
  _TransportOpenError(this.cause, this.stackTrace);

  final Object cause;
  final StackTrace stackTrace;
}
