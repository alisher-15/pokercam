import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart'
    show MediaStream, MediaStreamTrack;
import 'package:shared/shared.dart';
import 'package:viewer_windows/src/store.dart';
import 'package:viewer_windows/src/subscriber.dart';

const tableId = '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f88';

const connection = Connection(
  apiUrl: 'http://backend',
  refreshToken: 'refresh',
  viewerId: '8d4b1f6e-3a2c-4d9f-a7e5-1c6b0e9f2d74',
  clientId: '6a0d3b1e-2f4c-4e8a-b1d7-5c9e8f2a4b60',
);

final table = TableInfo(id: tableId, name: '1', number: 1, cameraOnline: true);

/// What the camera says it can do (camera.capabilities): focus, ISO and white balance; no contrast.
const capabilities = {
  'focus': {
    'supported': true,
    'modes': ['auto', 'manual'],
    'presets': <String>[],
    'min': 0,
    'max': 10,
    'step': 0.1,
    'current': {'mode': 'auto'},
    'default': {'mode': 'auto'},
  },
  'iso': {
    'supported': true,
    'modes': ['auto', 'manual'],
    'presets': <String>[],
    'min': 100,
    'max': 3200,
    'step': 50,
    'current': {'mode': 'manual', 'value': 400},
    'default': {'mode': 'auto'},
  },
  'exposure': {'supported': false, 'modes': <String>[], 'presets': <String>[]},
  'brightness': {
    'supported': false,
    'modes': <String>[],
    'presets': <String>[],
  },
  'contrast': {'supported': false, 'modes': <String>[], 'presets': <String>[]},
  'white_balance': {
    'supported': true,
    'modes': ['auto', 'preset'],
    'presets': ['daylight', 'shade'],
    'current': {'mode': 'auto'},
  },
  'zoom': {'supported': false, 'modes': <String>[], 'presets': <String>[]},
};

/// media-server as a viewer sees it: answers join, sends the room's state like welcome() does, records what
/// the viewer sends and lets the test push the camera's messages.
class FakeMediaServer {
  late final HttpServer _http;
  final peers = <WebSocket>[];
  final received = <Map<String, dynamic>>[];
  final _arrivals = StreamController<Map<String, dynamic>>.broadcast();
  int joins = 0;

  /// The answer to the next joins: null to accept, a signaling error code to refuse.
  String? refuseJoin;

  /// What the room says right after a join.
  String license = 'active';
  bool cameraLive = true;

  /// camera.set gets this camera.ack (ok, or an error code); null: no answer.
  String? ackError;
  bool answerSets = true;

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
    final payload = msg['payload'] as Map<String, dynamic>;
    switch (msg['type']) {
      case 'signaling.join':
        joins++;
        final refusal = refuseJoin;
        if (refusal != null) {
          send(ws, 'signaling.error', {
            'request_id': msg['id'],
            'code': refusal,
            'message': refusal,
          });
          return;
        }
        send(ws, 'signaling.join.result', {
          'request_id': msg['id'],
          'role': 'viewer',
          'peer_id': 'p$joins',
          'session_id': '00000000-0000-4000-8000-00000000000$joins',
        });
        send(ws, 'license.status', {'status': license});
        send(ws, 'stream.status', {
          'status': cameraLive ? 'live' : 'offline',
          'since': 1793500000000,
        });
        send(ws, 'camera.capabilities', {'params': capabilities});
        if (cameraLive) {
          send(ws, 'signaling.new_producer', {
            'producer_id': 'prod-$joins',
            'kind': 'video',
          });
        }
      case 'camera.set':
        if (!answerSets) return;
        final error = ackError;
        send(ws, 'camera.ack', {
          'request_id': msg['id'],
          'ok': error == null,
          if (error == null) 'applied': payload['control'],
          'error': ?error,
        });
        if (error == null) {
          send(ws, 'camera.state', {
            'controls': {payload['param'] as String: payload['control']},
          });
        }
    }
  }

  void send(WebSocket ws, String type, Map<String, dynamic> payload) => ws.add(
    jsonEncode({
      'type': type,
      'id': newUuid(),
      'ts': 1,
      'table_id': tableId,
      'payload': payload,
    }),
  );

  /// Sends a message to the latest viewer connection.
  void push(String type, Map<String, dynamic> payload) =>
      send(peers.last, type, payload);

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

class FakeStream extends MediaStream {
  FakeStream(String id) : super(id, 'test');

  @override
  bool? get active => true;

  @override
  Future<void> getMediaTracks() async {}

  @override
  Future<void> addTrack(
    MediaStreamTrack track, {
    bool addToNative = true,
  }) async {}

  @override
  Future<void> removeTrack(
    MediaStreamTrack track, {
    bool removeFromNative = true,
  }) async {}

  @override
  List<MediaStreamTrack> getTracks() => const [];

  @override
  List<MediaStreamTrack> getAudioTracks() => const [];

  @override
  List<MediaStreamTrack> getVideoTracks() => const [];
}

/// No WebRTC: counts what the session asks for and hands back a stream object.
class FakeSubscriber implements Subscriber {
  int prepared = 0;
  int consumed = 0;
  int closed = 0;
  final _failures = StreamController<void>.broadcast();

  void fail() => _failures.add(null);

  @override
  Stream<void> get failures => _failures.stream;

  @override
  Future<void> prepare(ControlSocket socket) async => prepared++;

  @override
  Future<MediaStream> consume(ControlSocket socket) async =>
      FakeStream('stream-${++consumed}');

  @override
  Future<ReceiveStats?> stats() async => const ReceiveStats(
    width: 1920,
    height: 1080,
    fps: 30,
    freezes: 0,
    packetsLost: 0,
    codec: 'video/H264',
  );

  @override
  Future<void> close() async => closed++;
}

class MemoryStore implements ConnectionStore {
  MemoryStore([this.value]);

  Connection? value;
  String? last;

  @override
  Future<Connection?> load() async => value;

  @override
  Future<void> save(Connection connection) async {
    value = connection;
    last = connection.apiUrl;
  }

  @override
  Future<void> clear() async => value = null;

  @override
  Future<String?> lastApiUrl() async => last;

  @override
  Future<String> machineId() async => 'machine-1';
}

/// The backend for the app: activation, tokens with the fake media-server's address, tables, pairing codes.
ApiClient fakeBackend(
  String url, {
  required String mediaUrl,
  int tokenStatus = 200,
  String? activationError,
  List<http.Request>? sent,
}) => ApiClient(
  url,
  client: MockClient((request) async {
    sent?.add(request);
    final path = request.url.path;
    http.Response error(int status, String code) => http.Response(
      jsonEncode({
        'detail': {'code': code, 'message': code},
      }),
      status,
    );
    if (path.endsWith('/viewer/activate')) {
      if (activationError != null) return error(401, activationError);
      return http.Response(
        jsonEncode({
          'refresh_token': 'refresh',
          'viewer_id': connection.viewerId,
          'client_id': connection.clientId,
        }),
        200,
      );
    }
    if (path.endsWith('/auth/token')) {
      if (tokenStatus != 200) return error(tokenStatus, 'access_revoked');
      return http.Response(
        jsonEncode({
          'access_token': 'access',
          'token_type': 'bearer',
          'expires_in': 43200,
          'media_url': mediaUrl,
        }),
        200,
      );
    }
    if (path.endsWith('/license')) {
      return http.Response(
        '{"status":"active","paid_until":"2026-11-30T12:00:00Z","grace_until":"2026-12-03T12:00:00Z"}',
        200,
      );
    }
    if (path.endsWith('/tables')) {
      return http.Response(
        jsonEncode({
          'tables': [
            {'id': tableId, 'name': '1', 'number': 1, 'camera_online': true},
            {
              'id': '0b5e9c7a-1d2f-4e3a-8c6b-9f0a1e2d3c4b',
              'name': '2',
              'number': 2,
              'camera_online': false,
              'camera_last_seen_at': '2026-10-30T10:00:00Z',
            },
          ],
        }),
        200,
      );
    }
    if (path.endsWith('/pairing-code')) {
      return http.Response(
        '{"code":"482913","expires_at":"2026-10-30T18:05:00Z","qr_payload":"{\\"v\\":1,\\"api\\":\\"http://backend\\",\\"code\\":\\"482913\\"}"}',
        200,
      );
    }
    return http.Response('{}', 404);
  }),
);
