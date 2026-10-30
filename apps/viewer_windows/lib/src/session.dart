import 'dart:async';

import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart'
    show MediaStream;
import 'package:shared/shared.dart';

import 'subscriber.dart';

enum WatchPhase {
  connecting,

  /// Joined; the table's camera is not publishing.
  waiting,
  live,
  reconnecting,

  /// The license blocks the club (SPEC 8.4): no video, retried every [TableSession.blockedRetry].
  blocked,

  /// The table already has as many viewers as the server allows.
  roomFull,

  /// This PC's access was revoked in the admin panel: activate again.
  unauthorized,
  stopped,
}

/// One device.alert, for the toast and the journal of the last 50 (SPEC 8.4).
class AlertEntry {
  const AlertEntry({
    required this.kind,
    required this.level,
    required this.messageKey,
    required this.at,
  });

  final AlertKind kind;
  final AlertLevel level;
  final String messageKey;
  final DateTime at;
}

const _keep = Object();

/// What the watch screen shows.
class WatchState {
  const WatchState({
    this.phase = WatchPhase.connecting,
    this.license,
    this.graceUntil,
    this.stream,
    this.cameraOfflineSince,
    this.telemetry,
    this.receive,
    this.capabilities,
    this.controls = const {},
    this.alerts = const [],
  });

  final WatchPhase phase;
  final RoomLicenseStatus? license;
  final DateTime? graceUntil;

  /// The camera's video on this PC, while live.
  final MediaStream? stream;

  /// When the camera went offline (stream.status), for the "offline since" placeholder (SPEC 8.5).
  final DateTime? cameraOfflineSince;
  final DeviceTelemetryPayload? telemetry;
  final ReceiveStats? receive;
  final CameraParamCapabilities? capabilities;

  /// The camera's current settings (camera.state, else the capabilities' current values).
  final Map<CameraParam, CameraControl> controls;

  /// Newest first, at most 50.
  final List<AlertEntry> alerts;

  WatchState copyWith({
    WatchPhase? phase,
    RoomLicenseStatus? license,
    Object? graceUntil = _keep,
    Object? stream = _keep,
    Object? cameraOfflineSince = _keep,
    DeviceTelemetryPayload? telemetry,
    Object? receive = _keep,
    CameraParamCapabilities? capabilities,
    Map<CameraParam, CameraControl>? controls,
    List<AlertEntry>? alerts,
  }) => WatchState(
    phase: phase ?? this.phase,
    license: license ?? this.license,
    graceUntil: identical(graceUntil, _keep)
        ? this.graceUntil
        : graceUntil as DateTime?,
    stream: identical(stream, _keep) ? this.stream : stream as MediaStream?,
    cameraOfflineSince: identical(cameraOfflineSince, _keep)
        ? this.cameraOfflineSince
        : cameraOfflineSince as DateTime?,
    telemetry: telemetry ?? this.telemetry,
    receive: identical(receive, _keep)
        ? this.receive
        : receive as ReceiveStats?,
    capabilities: capabilities ?? this.capabilities,
    controls: controls ?? this.controls,
    alerts: alerts ?? this.alerts,
  );
}

/// The camera's answer to one camera.set; ok false with no error means it did not answer in time.
class SetResult {
  const SetResult({required this.ok, this.error, this.applied});

  final bool ok;
  final CameraErrorCode? error;
  final CameraControl? applied;
}

/// One table on this PC (SPEC 8): join its room on media-server, play the camera live, carry the camera's
/// reports to the screen and camera.set to the camera; reconnect 1-2-4-8-10 s for ever after a loss.
class TableSession {
  TableSession({
    required this.tableId,
    required this.tokens,
    required this.subscriber,
    required JsonLog log,
    this.statsEvery = const Duration(seconds: 1),
    this.blockedRetry = const Duration(seconds: 30),
    this.ackTimeout = const Duration(seconds: 5),
    Backoff? backoff,
    Future<ControlSocket> Function(String url, String tableId)? connect,
  }) : _log = log.withContext({'table_id': tableId}),
       _backoff = backoff ?? Backoff(),
       _connect = connect ?? ControlSocket.connect;

  final String tableId;

  /// An access token for this table and media-server's address (POST /auth/token with table_id).
  final Future<TokenResponse> Function(String tableId) tokens;
  final Subscriber subscriber;
  final Duration statsEvery;
  final Duration blockedRetry;
  final Duration ackTimeout;
  final JsonLog _log;
  final Backoff _backoff;
  final Future<ControlSocket> Function(String url, String tableId) _connect;

  final _states = StreamController<WatchState>.broadcast();
  final _alerts = StreamController<AlertEntry>.broadcast();
  final _acks = <String, Completer<SetResult>>{};
  WatchState _state = const WatchState();
  ControlSocket? _socket;
  JsonLog? _sessionLog;
  bool _stopped = false;
  bool _prepared = false;
  bool _producerAnnounced = false;
  Completer<void>? _wake;
  Timer? _statsTimer;

  WatchState get state => _state;
  Stream<WatchState> get states => _states.stream;

  /// Each device.alert as it arrives (the screen shows a toast).
  Stream<AlertEntry> get alerts => _alerts.stream;
  JsonLog get log => _sessionLog ?? _log;

  void _emit(WatchState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  /// The phase while connected, from what the room said last.
  WatchPhase get _connectedPhase => _state.license == RoomLicenseStatus.BLOCKED
      ? WatchPhase.blocked
      : _state.stream != null
      ? WatchPhase.live
      : WatchPhase.waiting;

  /// Runs until [stop] or until this PC must activate again; returns the last phase.
  Future<WatchPhase> run() async {
    _statsTimer = Timer.periodic(statsEvery, (_) => unawaited(_refreshStats()));
    while (!_stopped) {
      final ended = await _connectOnce();
      if (ended != null) return _finish(ended);
      if (_stopped) break;
      final waitLong =
          _state.phase == WatchPhase.blocked ||
          _state.phase == WatchPhase.roomFull;
      final pause = waitLong ? blockedRetry : _backoff.next();
      if (!waitLong) _emit(_state.copyWith(phase: WatchPhase.reconnecting));
      log.info('reconnecting', {
        'in_ms': pause.inMilliseconds,
        'attempt': _backoff.attempt,
      });
      await _sleep(pause);
    }
    return _finish(WatchPhase.stopped);
  }

  Future<void> stop() async {
    _stopped = true;
    _statsTimer?.cancel();
    if (_wake?.isCompleted == false) _wake?.complete();
    final socket = _socket;
    if (socket != null && socket.isOpen) await socket.close();
  }

  WatchPhase _finish(WatchPhase phase) {
    _statsTimer?.cancel();
    _emit(_state.copyWith(phase: phase, stream: null, receive: null));
    unawaited(_states.close());
    unawaited(_alerts.close());
    return phase;
  }

  /// One connection: returns [WatchPhase.unauthorized] when this PC must activate again, null to reconnect.
  Future<WatchPhase?> _connectOnce() async {
    ControlSocket? socket;
    StreamSubscription<Map<String, dynamic>>? messages;
    StreamSubscription<void>? failures;
    try {
      final token = await tokens(tableId);
      final opened = await _connect(token.mediaUrl, tableId);
      socket = opened;
      // Listen before joining: the room's state (license, camera, its producer) follows join's reply at once.
      messages = opened.messages.listen(
        (msg) => unawaited(_onMessage(opened, msg)),
      );
      final joined = await opened.request('signaling.join', {
        'token': token.accessToken,
      });
      _sessionLog = _log.withContext({'session_id': joined['session_id']});
      log.info('joined', {'media_url': token.mediaUrl});
      _socket = opened;
      await subscriber.prepare(opened);
      _prepared = true;
      final lost = Completer<void>();
      failures = subscriber.failures.listen((_) {
        if (!lost.isCompleted) lost.complete();
      });
      _backoff.reset();
      if (_producerAnnounced) {
        await _consume(opened);
      } else {
        _emit(_state.copyWith(phase: _connectedPhase));
      }
      await Future.any([opened.done, lost.future]);
      log.warn('connection lost', {'close_code': opened.closeCode});
    } on ApiException catch (e) {
      if (e.unauthorized) {
        log.warn('the backend no longer knows this PC', {'code': e.code});
        return WatchPhase.unauthorized;
      }
      if (e.status == 403) {
        _emit(
          _state.copyWith(
            phase: WatchPhase.blocked,
            license: RoomLicenseStatus.BLOCKED,
          ),
        );
      }
      log.warn('no access token', {'code': e.code, 'status': e.status});
    } on SignalingException catch (e) {
      switch (e.code) {
        case 'license_blocked':
          _emit(
            _state.copyWith(
              phase: WatchPhase.blocked,
              license: RoomLicenseStatus.BLOCKED,
            ),
          );
        case 'room_full':
          _emit(_state.copyWith(phase: WatchPhase.roomFull));
      }
      log.warn('signaling refused', {'code': e.code, 'message': e.message});
    } on Object catch (e) {
      log.warn('connection failed', {'error': '$e'});
    } finally {
      _socket = null;
      _prepared = false;
      _producerAnnounced = false;
      await messages?.cancel();
      await failures?.cancel();
      await subscriber.close();
      for (final waiting in _acks.values) {
        if (!waiting.isCompleted) waiting.complete(const SetResult(ok: false));
      }
      _acks.clear();
      if (_state.stream != null) {
        _emit(_state.copyWith(stream: null, receive: null));
      }
      if (socket != null && socket.isOpen) await socket.close();
    }
    return null;
  }

  Future<void> _consume(ControlSocket socket) async {
    try {
      final stream = await subscriber.consume(socket);
      if (!identical(_socket, socket)) return;
      _emit(
        _state.copyWith(
          stream: stream,
          cameraOfflineSince: null,
          phase: _state.license == RoomLicenseStatus.BLOCKED
              ? WatchPhase.blocked
              : WatchPhase.live,
        ),
      );
      log.info('live');
    } on Object catch (e) {
      // Without the video the connection is no use: start over.
      log.warn('consume failed', {'error': '$e'});
      if (socket.isOpen) await socket.close();
    }
  }

  Future<void> _onMessage(
    ControlSocket socket,
    Map<String, dynamic> msg,
  ) async {
    final payload = msg['payload'] as Map<String, dynamic>;
    switch (msg['type']) {
      case 'license.status':
        final license = LicenseStatusPayload.fromJson(payload);
        final grace = license.graceUntil;
        _emit(
          _state.copyWith(
            license: license.status,
            graceUntil: grace == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(grace),
          ),
        );
        if (_prepared) _emit(_state.copyWith(phase: _connectedPhase));
      case 'stream.status':
        final status = StreamStatusPayload.fromJson(payload);
        _emit(
          _state.copyWith(
            cameraOfflineSince: status.status == StreamState.OFFLINE
                ? DateTime.fromMillisecondsSinceEpoch(status.since)
                : null,
          ),
        );
      case 'signaling.new_producer':
        _producerAnnounced = true;
        if (_prepared && identical(_socket, socket)) await _consume(socket);
      case 'signaling.consumer_closed':
        _producerAnnounced = false;
        _emit(_state.copyWith(stream: null, receive: null));
        if (_prepared) _emit(_state.copyWith(phase: _connectedPhase));
      case 'camera.capabilities':
        final caps = CameraCapabilitiesPayload.fromJson(payload).params;
        _emit(
          _state.copyWith(
            capabilities: caps,
            controls: {..._currentOf(caps), ..._state.controls},
          ),
        );
      case 'camera.state':
        final controls = CameraStatePayload.fromJson(payload).controls.toJson();
        _emit(
          _state.copyWith(
            controls: {
              ..._state.controls,
              for (final e in controls.entries)
                if (e.value != null)
                  cameraParamValues.map[e.key]!: CameraControl.fromJson(
                    e.value as Map<String, dynamic>,
                  ),
            },
          ),
        );
      case 'camera.ack':
        final ack = CameraAckPayload.fromJson(payload);
        _acks
            .remove(ack.requestId)
            ?.complete(
              SetResult(ok: ack.ok, error: ack.error, applied: ack.applied),
            );
      case 'device.telemetry':
        _emit(
          _state.copyWith(telemetry: DeviceTelemetryPayload.fromJson(payload)),
        );
      case 'device.alert':
        final alert = DeviceAlertPayload.fromJson(payload);
        final entry = AlertEntry(
          kind: alert.kind,
          level: alert.level,
          messageKey: alert.messageKey,
          at: DateTime.now(),
        );
        _emit(
          _state.copyWith(alerts: [entry, ..._state.alerts].take(50).toList()),
        );
        if (!_alerts.isClosed) _alerts.add(entry);
    }
  }

  static Map<CameraParam, CameraControl> _currentOf(
    CameraParamCapabilities caps,
  ) {
    final json = caps.toJson();
    return {
      for (final e in json.entries)
        if (e.value case {
          'supported': true,
          'current': final Map<String, dynamic> current,
        })
          cameraParamValues.map[e.key]!: CameraControl.fromJson(current),
    };
  }

  /// camera.set (SPEC 5.3): completes with the camera's camera.ack, or not ok after [ackTimeout].
  Future<SetResult> set(CameraParam param, CameraControl control) {
    final socket = _socket;
    if (socket == null || !socket.isOpen) {
      return Future.value(
        const SetResult(ok: false, error: CameraErrorCode.CAMERA_UNAVAILABLE),
      );
    }
    final id = socket.send('camera.set', {
      'param': cameraParamValues.reverse[param],
      'control': withoutNulls(control.toJson()),
    });
    final answer = Completer<SetResult>();
    _acks[id] = answer;
    return answer.future.timeout(
      ackTimeout,
      onTimeout: () {
        _acks.remove(id);
        return const SetResult(ok: false);
      },
    );
  }

  Future<void> _refreshStats() async {
    if (_state.stream == null) return;
    try {
      final stats = await subscriber.stats();
      if (stats != null && _state.stream != null) {
        _emit(_state.copyWith(receive: stats));
      }
    } on Object catch (e) {
      log.warn('stats failed', {'error': '$e'});
    }
  }

  /// The pause before reconnecting; [stop] ends it at once, its timer included.
  Future<void> _sleep(Duration pause) {
    final wake = Completer<void>();
    _wake = wake;
    final timer = Timer(pause, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(timer.cancel);
  }
}
