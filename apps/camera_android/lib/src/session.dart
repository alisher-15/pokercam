import 'dart:async';

import 'package:shared/shared.dart';

import 'media.dart';
import 'platform/camera2.dart';
import 'platform/device.dart';
import 'policy.dart';
import 'store.dart';
import 'tokens.dart';

enum SessionPhase {
  connecting,
  live,
  reconnecting,

  /// The license blocks the table: connected, not publishing, waiting for it to come back.
  blocked,

  /// Unpaired or replaced by another phone (SPEC 6.4): pair again.
  unpaired,
  stopped,
}

/// What the broadcast screen shows.
class SessionState {
  const SessionState({
    this.phase = SessionPhase.connecting,
    this.license,
    this.graceUntil,
    this.stats,
    this.device,
    this.banners = const [],
  });

  final SessionPhase phase;
  final RoomLicenseStatus? license;
  final DateTime? graceUntil;
  final PublishStats? stats;
  final DeviceSnapshot? device;

  /// Alerts shown over the preview (overheating, low battery), as ARB keys.
  final List<Alert> banners;

  SessionState copyWith({
    SessionPhase? phase,
    RoomLicenseStatus? license,
    DateTime? graceUntil,
    PublishStats? stats,
    DeviceSnapshot? device,
    List<Alert>? banners,
  }) => SessionState(
    phase: phase ?? this.phase,
    license: license ?? this.license,
    graceUntil: graceUntil ?? this.graceUntil,
    stats: stats ?? this.stats,
    device: device ?? this.device,
    banners: banners ?? this.banners,
  );
}

/// One table's broadcast from this phone (SPEC 6): connect, join, publish, carry out camera.set, send
/// telemetry and alerts; reconnect 1-2-4-8-10 s for ever after a loss, restoring the camera settings.
class BroadcastSession {
  BroadcastSession({
    required this.pairing,
    required this.tokens,
    required this.publisher,
    required this.camera,
    required this.device,
    required this.settings,
    required JsonLog log,
    this.telemetryEvery = const Duration(seconds: 5),
    this.blockedRetry = const Duration(seconds: 30),
    Backoff? backoff,
    DateTime Function()? now,
    Future<ControlSocket> Function(String url, String tableId)? connect,
  }) : _log = log.withContext({
         'table_id': pairing.tableId,
         'device_id': pairing.deviceId,
       }),
       _backoff = backoff ?? Backoff(),
       _now = now ?? DateTime.now,
       _connect = connect ?? ControlSocket.connect;

  final Pairing pairing;
  final TokenSource tokens;
  final Publisher publisher;
  final CameraControlApi camera;
  final DeviceApi device;
  final SettingsStore settings;
  final Duration telemetryEvery;
  final Duration blockedRetry;
  final JsonLog _log;
  final Backoff _backoff;
  final DateTime Function() _now;
  final Future<ControlSocket> Function(String url, String tableId) _connect;

  final thermal = ThermalPolicy();
  final battery = BatteryPolicy();
  final _states = StreamController<SessionState>.broadcast();
  SessionState _state = const SessionState();
  ControlSocket? _socket;
  String? _trackId;
  JsonLog? _sessionLog;
  bool _stopped = false;
  bool _publishing = false;
  Completer<void>? _wake;
  Timer? _telemetry;
  Future<void> _cameraQueue = Future.value();

  /// Current setting of every supported parameter (camera.state).
  final _controls = <String, CameraControl>{};
  CameraInfo? _info;

  SessionState get state => _state;
  Stream<SessionState> get states => _states.stream;
  JsonLog get log => _sessionLog ?? _log;

  void _emit(SessionState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  /// Runs until [stop] or until the phone is unpaired; returns the last phase.
  Future<SessionPhase> run() async {
    _trackId = await publisher.openCamera();
    _telemetry = Timer.periodic(telemetryEvery, (_) => unawaited(_tick()));
    unawaited(_tick());
    while (!_stopped) {
      final ended = await _connectOnce();
      if (ended != null) {
        _finish(ended);
        return ended;
      }
      if (_stopped) break;
      final pause = _state.phase == SessionPhase.blocked
          ? blockedRetry
          : _backoff.next();
      if (_state.phase != SessionPhase.blocked) {
        _emit(_state.copyWith(phase: SessionPhase.reconnecting));
      }
      log.info('reconnecting', {
        'in_ms': pause.inMilliseconds,
        'attempt': _backoff.attempt,
      });
      await _sleep(pause);
    }
    _finish(SessionPhase.stopped);
    return SessionPhase.stopped;
  }

  /// One connection: returns [SessionPhase.unpaired] when this phone must pair again, null to reconnect.
  Future<SessionPhase?> _connectOnce() async {
    ControlSocket? socket;
    StreamSubscription<Map<String, dynamic>>? messages;
    StreamSubscription<void>? failures;
    try {
      final token = await tokens.get();
      final opened = await _connect(token.mediaUrl, pairing.tableId);
      socket = opened;
      _socket = opened;
      // Listen before joining: license.status follows join's reply at once.
      messages = opened.messages.listen(
        (msg) => unawaited(_onMessage(opened, msg)),
      );
      final joined = await opened.request('signaling.join', {
        'token': token.accessToken,
      });
      _sessionLog = _log.withContext({'session_id': joined['session_id']});
      log.info('joined', {'media_url': token.mediaUrl});
      final lost = Completer<void>();
      failures = publisher.failures.listen((_) {
        if (!lost.isCompleted) lost.complete();
      });
      if (_state.license != RoomLicenseStatus.BLOCKED) await _publish(socket);
      _backoff.reset();
      await Future.any([socket.done, lost.future]);
      if (socket.closeCode == ControlSocket.replacedByAnotherCamera) {
        log.warn('replaced by another camera');
        return SessionPhase.unpaired;
      }
      log.warn('connection lost', {'close_code': socket.closeCode});
    } on ApiException catch (e) {
      if (e.unauthorized) {
        log.warn('the backend no longer knows this phone', {'code': e.code});
        return SessionPhase.unpaired;
      }
      if (e.status == 403) {
        // license_expired, license_suspended, no_license: no token until the club pays again.
        _emit(
          _state.copyWith(
            phase: SessionPhase.blocked,
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
              phase: SessionPhase.blocked,
              license: RoomLicenseStatus.BLOCKED,
            ),
          );
        case 'forbidden':
          // "this phone is no longer the table's camera" (stage 3): another phone took the table.
          log.warn('media-server refused this phone', {'message': e.message});
          return SessionPhase.unpaired;
        case 'unauthorized':
          tokens.invalidate();
      }
      log.warn('signaling refused', {'code': e.code, 'message': e.message});
    } on Object catch (e) {
      log.warn('connection failed', {'error': '$e'});
    } finally {
      _publishing = false;
      await messages?.cancel();
      await failures?.cancel();
      await publisher.unpublish();
      _socket = null;
      if (socket != null && socket.isOpen) await socket.close();
    }
    return null;
  }

  /// Produces the camera and tells the room what it can do and how it is set (restoring saved settings).
  Future<void> _publish(ControlSocket socket) async {
    await publisher.publish(socket, maxBitrate: thermal.bitrate);
    _publishing = true;
    final trackId = _trackId!;
    final info = await camera.capabilities(trackId);
    _info = info;
    final saved = await settings.load();
    final applied = saved.isEmpty
        ? <String, CameraControl>{}
        : await camera.apply(trackId, saved);
    _controls
      ..clear()
      ..addAll(_currentControls(info))
      ..addAll(applied);
    socket.send('camera.capabilities', {
      'params': withoutNulls(info.params.toJson()),
    });
    socket.send('camera.state', {'controls': _controlsJson()});
    final live = _state.license == RoomLicenseStatus.BLOCKED
        ? SessionPhase.blocked
        : SessionPhase.live;
    _emit(_state.copyWith(phase: live));
    log.info('live', {
      'capture_size': info.captureSize,
      'restored': applied.keys.toList(),
    });
  }

  static Map<String, CameraControl> _currentControls(CameraInfo info) {
    final json = info.params.toJson();
    return {
      for (final e in json.entries)
        if ((e.value as Map<String, dynamic>)['current'] != null)
          e.key: CameraControl.fromJson(
            (e.value as Map<String, dynamic>)['current']
                as Map<String, dynamic>,
          ),
    };
  }

  Map<String, dynamic> _controlsJson() => {
    for (final e in _controls.entries) e.key: withoutNulls(e.value.toJson()),
  };

  Future<void> _onMessage(
    ControlSocket socket,
    Map<String, dynamic> msg,
  ) async {
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};
    switch (msg['type']) {
      case 'camera.set':
        // One at a time, in order: the last one wins (SPEC 5.3).
        _cameraQueue = _cameraQueue.then(
          (_) => _onCameraSet(socket, msg['id'] as String, payload),
        );
      case 'license.status':
        await _onLicense(socket, payload);
    }
  }

  Future<void> _onCameraSet(
    ControlSocket socket,
    String requestId,
    Map<String, dynamic> payload,
  ) async {
    final trackId = _trackId;
    final param = cameraParamValues.map[payload['param']];
    if (trackId == null || param == null || !_publishing) {
      socket.send('camera.ack', {
        'request_id': requestId,
        'ok': false,
        'error': 'camera_unavailable',
      });
      return;
    }
    try {
      final control = CameraControl.fromJson(
        payload['control'] as Map<String, dynamic>,
      );
      final result = await camera.set(trackId, param, control);
      final name = cameraParamValues.reverse[param]!;
      _controls[name] = result.applied;
      await settings.save(name, result.applied);
      socket.send('camera.ack', {
        'request_id': requestId,
        'ok': true,
        'applied': withoutNulls(result.applied.toJson()),
      });
      socket.send('camera.state', {'controls': _controlsJson()});
      log.info('camera set', {
        'param': name,
        'confirmed': result.confirmed,
        'after_ms': result.afterMs,
      });
    } on CameraControlError catch (e) {
      const known = {
        'unsupported_param',
        'unsupported_mode',
        'out_of_range',
        'camera_unavailable',
      };
      socket.send('camera.ack', {
        'request_id': requestId,
        'ok': false,
        'error': known.contains(e.code) ? e.code : 'internal',
      });
      log.warn('camera set refused', {'code': e.code, 'message': e.message});
    } on Object catch (e) {
      socket.send('camera.ack', {
        'request_id': requestId,
        'ok': false,
        'error': 'internal',
      });
      log.error('camera set failed', {'error': '$e'});
    }
  }

  Future<void> _onLicense(
    ControlSocket socket,
    Map<String, dynamic> payload,
  ) async {
    final status = roomLicenseStatusValues.map[payload['status']];
    if (status == null) return;
    final grace = payload['grace_until'] as num?;
    final wasBlocked = _state.license == RoomLicenseStatus.BLOCKED;
    _emit(
      _state.copyWith(
        license: status,
        graceUntil: grace == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(grace.toInt()),
        phase: status == RoomLicenseStatus.BLOCKED
            ? SessionPhase.blocked
            : null,
      ),
    );
    if (status == RoomLicenseStatus.BLOCKED) {
      // media-server has closed the producer (SPEC 7.1); stay in the room until the license is back.
      log.warn('license blocked');
      _publishing = false;
      await publisher.unpublish();
    } else if (wasBlocked && socket.isOpen) {
      log.info('license back', {'status': payload['status']});
      await _publish(socket);
    }
  }

  /// Every [telemetryEvery]: policies (heat → bitrate, battery), device.telemetry, the screen's figures.
  Future<void> _tick() async {
    if (_stopped) return;
    try {
      final snapshot = await device.snapshot();
      final stats = _publishing ? await publisher.stats() : null;
      final heat = thermal.update(snapshot.thermal, snapshot.tempC, _now());
      if (heat != null) {
        log.warn('heat level ${thermal.level}', {
          'bitrate': thermal.bitrate,
          'thermal': thermalStatusValues.reverse[snapshot.thermal],
        });
        await publisher.setMaxBitrate(thermal.bitrate);
      }
      final power = battery.update(snapshot.batteryPct, snapshot.charging);
      final socket = _socket;
      for (final alert in [?heat, ?power]) {
        socket?.send('device.alert', alert.toPayload());
      }
      if (socket != null && _publishing) {
        socket.send('device.telemetry', {
          'battery_pct': snapshot.batteryPct,
          'charging': snapshot.charging,
          'temp_c': snapshot.tempC,
          'thermal_status': thermalStatusValues.reverse[snapshot.thermal],
          'network': withoutNulls({
            ...snapshot.network.toJson(),
            'rtt_ms': stats?.rttMs,
          }),
          'stream': {
            'bitrate_kbps': stats?.bitrateKbps ?? 0,
            'fps': stats?.fps ?? 0,
            'dropped_frames': stats?.droppedFrames ?? 0,
          },
        });
      }
      final banners = [
        if (thermal.level == 2)
          const Alert(
            AlertKind.OVERHEATING,
            AlertLevel.CRITICAL,
            'alertOverheatingCritical',
          ),
        if (thermal.level == 1)
          const Alert(
            AlertKind.OVERHEATING,
            AlertLevel.WARNING,
            'alertOverheating',
          ),
        ?battery.banner,
      ];
      _emit(_state.copyWith(device: snapshot, stats: stats, banners: banners));
      // Back online while waiting to reconnect: try now rather than at the end of the pause.
      if (snapshot.online && _state.phase == SessionPhase.reconnecting) {
        _wake?.complete();
      }
    } on Object catch (e) {
      log.warn('telemetry failed', {'error': '$e'});
    }
  }

  Future<void> _sleep(Duration pause) async {
    final wake = Completer<void>();
    _wake = wake;
    await Future.any([Future<void>.delayed(pause), wake.future]);
    _wake = null;
  }

  /// Ends the broadcast: closes the connection and the camera.
  Future<void> stop() async {
    _stopped = true;
    if (_wake?.isCompleted == false) _wake?.complete();
    final socket = _socket;
    if (socket != null && socket.isOpen) await socket.close();
  }

  void _finish(SessionPhase phase) {
    _telemetry?.cancel();
    _emit(_state.copyWith(phase: phase));
    unawaited(_states.close());
  }

  /// The camera's capabilities as read at the last publication (for logs and tests).
  CameraInfo? get cameraInfo => _info;
}
