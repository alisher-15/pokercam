import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera_android/src/media.dart';
import 'package:camera_android/src/platform/camera2.dart';
import 'package:camera_android/src/platform/device.dart';
import 'package:camera_android/src/store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart'
    show MediaStream;
import 'package:shared/shared.dart';

const tableId = '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f88';
const deviceId = '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f89';

const pairing = Pairing(
  apiUrl: 'http://backend',
  refreshToken: 'refresh',
  deviceId: deviceId,
  tableId: tableId,
  clientId: '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f80',
);

/// media-server as the camera sees it: answers join, records what the camera sends, lets the test push messages.
class FakeMediaServer {
  late final HttpServer _http;
  final peers = <WebSocket>[];
  final received = <Map<String, dynamic>>[];
  final _arrivals = StreamController<Map<String, dynamic>>.broadcast();
  int joins = 0;

  /// The answer to the next joins: null to accept, a signaling error code to refuse.
  String? refuseJoin;

  /// license.status sent right after a join, like media-server does for a camera.
  String licenseAtJoin = 'active';

  String get url => 'ws://127.0.0.1:${_http.port}/ws';

  static Future<FakeMediaServer> start() async {
    final server = FakeMediaServer();
    server._http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server._http.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      server.peers.add(ws);
      ws.listen(
        (data) => server._receive(
          ws,
          jsonDecode(data as String) as Map<String, dynamic>,
        ),
      );
    });
    return server;
  }

  void _receive(WebSocket ws, Map<String, dynamic> msg) {
    received.add(msg);
    _arrivals.add(msg);
    if (msg['type'] == 'signaling.join') {
      joins++;
      final refusal = refuseJoin;
      if (refusal != null) {
        _send(ws, 'signaling.error', {
          'request_id': msg['id'],
          'code': refusal,
          'message': refusal,
        });
        return;
      }
      _send(ws, 'signaling.join.result', {
        'request_id': msg['id'],
        'role': 'camera',
        'peer_id': 'p$joins',
        'session_id': '00000000-0000-4000-8000-00000000000$joins',
      });
      _send(ws, 'license.status', {'status': licenseAtJoin});
    }
  }

  void _send(WebSocket ws, String type, Map<String, dynamic> payload) => ws.add(
    jsonEncode({
      'type': type,
      'id': newUuid(),
      'ts': 1,
      'table_id': tableId,
      'payload': payload,
    }),
  );

  /// Sends a message to the latest camera connection; returns its id.
  String push(String type, Map<String, dynamic> payload) {
    final id = newUuid();
    peers.last.add(
      jsonEncode({
        'type': type,
        'id': id,
        'ts': 1,
        'table_id': tableId,
        'payload': payload,
      }),
    );
    return id;
  }

  /// The first message (already received or later) of this type that matches.
  Future<Map<String, dynamic>> next(
    String type, {
    bool Function(Map<String, dynamic> payload)? where,
    int after = 0,
  }) {
    bool test(Map<String, dynamic> m) =>
        m['type'] == type &&
        (where == null || where(m['payload'] as Map<String, dynamic>));
    for (final m in received.skip(after)) {
      if (test(m)) return Future.value(m);
    }
    return _arrivals.stream
        .firstWhere(test)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> closeLatest([int code = WebSocketStatus.normalClosure]) =>
      peers.last.close(code);

  Future<void> stop() => _http.close(force: true);
}

/// The backend's POST /auth/token: an access token and the fake media-server's address.
ApiClient backend(String mediaUrl, {int status = 200}) => ApiClient(
  'http://backend',
  client: MockClient(
    (request) async => status == 200
        ? http.Response(
            jsonEncode({
              'access_token': 'access',
              'token_type': 'bearer',
              'expires_in': 43200,
              'media_url': mediaUrl,
            }),
            200,
          )
        : http.Response(
            jsonEncode({
              'detail': {'code': 'access_revoked', 'message': 'revoked'},
            }),
            status,
          ),
  ),
);

class FakePublisher implements Publisher {
  int opened = 0;
  int closed = 0;
  int published = 0;
  int unpublished = 0;
  final bitrates = <int>[];
  final _failures = StreamController<void>.broadcast();

  @override
  MediaStream? get stream => null;

  @override
  Stream<void> get failures => _failures.stream;

  void fail() => _failures.add(null);

  @override
  Future<String> openCamera() async => 'track-${++opened}';

  @override
  Future<void> publish(ControlSocket socket, {required int maxBitrate}) async {
    published++;
    bitrates.add(maxBitrate);
  }

  @override
  Future<void> setMaxBitrate(int bitsPerSecond) async =>
      bitrates.add(bitsPerSecond);

  PublishStats statsValue = const PublishStats(
    bitrateKbps: 3900,
    fps: 30,
    droppedFrames: 2,
    rttMs: 12,
  );

  @override
  Future<PublishStats?> stats() async => statsValue;

  @override
  Future<void> unpublish() async => unpublished++;

  @override
  Future<void> closeCamera() async => closed++;
}

ParamCapability _manual(double min, double max) => ParamCapability(
  supported: true,
  modes: [ControlMode.AUTO, ControlMode.MANUAL],
  presets: [],
  min: min,
  max: max,
  step: 1,
  current: CameraControl(mode: ControlMode.AUTO),
);

ParamCapability _unsupported() =>
    ParamCapability(supported: false, modes: [], presets: []);

class FakeCamera implements CameraControlApi {
  final sets = <(CameraParam, CameraControl)>[];
  final applied = <Map<String, CameraControl>>[];

  /// Tracks whose capture session is gone (the system gave the camera to someone else).
  final lostTracks = <String>{};

  @override
  Future<Map<String, dynamic>> deviceInfo() async => {
    'h264_hardware_encoder': true,
  };

  @override
  Future<CameraInfo> capabilities(String trackId) async {
    if (lostTracks.contains(trackId)) {
      throw const CameraControlError(
        'camera_unavailable',
        'currentSession is null',
      );
    }
    return _info;
  }

  CameraInfo get _info => CameraInfo(
    params: CameraParamCapabilities(
      focus: _manual(0, 10),
      iso: _manual(100, 3200),
      exposure: _manual(100000, 33333333),
      brightness: _manual(-6, 6),
      contrast: _unsupported(),
      whiteBalance: _unsupported(),
      zoom: ParamCapability(
        supported: true,
        modes: [ControlMode.MANUAL],
        presets: [],
        min: 1,
        max: 4,
        step: 0.1,
        current: CameraControl(mode: ControlMode.MANUAL, value: 1),
      ),
    ),
    hardwareLevel: 'full',
    captureSize: '1920x1080',
    fpsRange: '30-30',
  );

  @override
  Future<CameraSetResult> set(
    String trackId,
    CameraParam param,
    CameraControl control,
  ) async {
    if (param == CameraParam.CONTRAST) {
      throw const CameraControlError('unsupported_param', 'contrast');
    }
    sets.add((param, control));
    final value = control.value;
    // Clamped like the plugin does.
    final clamped = param == CameraParam.ISO && value != null && value > 3200
        ? 3200.0
        : value;
    return CameraSetResult(
      CameraControl(mode: control.mode, value: clamped, preset: control.preset),
      confirmed: true,
      afterMs: 120,
    );
  }

  @override
  Future<Map<String, CameraControl>> apply(
    String trackId,
    Map<String, CameraControl> settings,
  ) async {
    applied.add(settings);
    return settings;
  }

  @override
  Future<void> forget() async {}
}

class FakeDevice implements DeviceApi {
  DeviceSnapshot snapshotValue = DeviceSnapshot(
    batteryPct: 80,
    charging: true,
    tempC: 31.5,
    thermal: ThermalStatus.NONE,
    network: NetworkInfo(type: NetworkType.WIFI, rssi: -55),
  );
  Permissions permissionsValue = const Permissions(
    camera: true,
    notifications: true,
    batteryUnrestricted: false,
  );
  int services = 0;

  @override
  Future<DeviceSnapshot> snapshot() async => snapshotValue;

  @override
  Future<({String androidId, String model})> identity() async =>
      (androidId: 'android-1', model: 'HUAWEI MatePad');

  @override
  Future<Permissions> permissions() async => permissionsValue;

  @override
  Future<Permissions> requestPermissions() async => permissionsValue;

  @override
  Future<void> requestBatteryExemption() async {}

  @override
  Future<void> startService({
    required String title,
    required String text,
    required String channel,
  }) async => services++;

  @override
  Future<void> stopService() async => services--;

  @override
  Future<void> keepScreenOn(bool on) async {}
}

class MemorySettings implements SettingsStore {
  final values = <String, CameraControl>{};

  @override
  Future<Map<String, CameraControl>> load() async => Map.of(values);

  @override
  Future<void> save(String param, CameraControl control) async =>
      values[param] = control;

  @override
  Future<void> clear() async => values.clear();
}

class MemoryPairings implements PairingStore {
  MemoryPairings([this.value]);

  Pairing? value;
  String? last;

  @override
  Future<Pairing?> load() async => value;

  @override
  Future<void> save(Pairing pairing) async {
    value = pairing;
    last = pairing.apiUrl;
  }

  @override
  Future<void> clear() async => value = null;

  @override
  Future<String?> lastApiUrl() async => last;
}
