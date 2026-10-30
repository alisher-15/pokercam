import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

void main() {
  group('pairing QR code', () {
    test('the backend\'s payload gives the server and the code', () {
      final qr = PairingQr.parse(
        '{"v":1,"api":"https://cam.club.kz/","code":"042137"}',
      );
      expect(qr?.apiUrl, 'https://cam.club.kz');
      expect(qr?.code, '042137');
    });

    test('anything else is not ours', () {
      for (final text in [
        'https://example.com',
        '{"v":2,"api":"https://a","code":"123456"}',
        '{"v":1,"api":"ftp://a","code":"123456"}',
        '{"v":1,"api":"https://a","code":"12345"}',
        '[1]',
      ]) {
        expect(PairingQr.parse(text), isNull, reason: text);
      }
    });

    test('a typed address gets a scheme and loses the trailing slash', () {
      expect(
        PairingQr.normalizeApiUrl(' 192.168.1.5:8000/ '),
        'http://192.168.1.5:8000',
      );
      expect(
        PairingQr.normalizeApiUrl('https://cam.club.kz'),
        'https://cam.club.kz',
      );
    });
  });

  test(
    'backoff: 1-2-4-8-10 s, then 10 s, from the start again after a success',
    () {
      final backoff = Backoff();
      expect(
        [for (var i = 0; i < 7; i++) backoff.next().inSeconds],
        [1, 2, 4, 8, 10, 10, 10],
      );
      backoff.reset();
      expect(backoff.next(), const Duration(seconds: 1));
    },
  );

  test('uuids are random version 4', () {
    final a = newUuid();
    expect(
      a,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(newUuid(), isNot(a));
  });

  group('backend API', () {
    test('pairing sends the contract body and reads the answer', () async {
      late http.Request sent;
      final api = ApiClient(
        'https://cam.club.kz/',
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'refresh_token': 'r',
              'device_id': '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f88',
              'table_id': '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f89',
              'client_id': '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f80',
            }),
            201,
          );
        }),
      );
      final paired = await api.pairDevice(
        code: '042137',
        model: 'HUAWEI MatePad',
        androidId: 'abc',
      );
      expect(sent.url.toString(), 'https://cam.club.kz/api/v1/device/pair');
      expect(jsonDecode(sent.body), {
        'code': '042137',
        'model': 'HUAWEI MatePad',
        'android_id': 'abc',
      });
      expect(paired.refreshToken, 'r');
    });

    test(
      'a token request leaves an absent table out and carries media_url back',
      () async {
        late http.Request sent;
        final api = ApiClient(
          'http://h',
          client: MockClient((request) async {
            sent = request;
            return http.Response(
              '{"access_token":"a","token_type":"bearer","expires_in":43200,"media_url":"ws://h:3000/ws"}',
              200,
            );
          }),
        );
        final token = await api.token('r');
        expect(jsonDecode(sent.body), {'refresh_token': 'r'});
        expect(token.mediaUrl, 'ws://h:3000/ws');
      },
    );

    test(
      'a PC activates, lists the tables and gets a pairing code (SPEC 8.1)',
      () async {
        final sent = <http.Request>[];
        final api = ApiClient(
          'http://h',
          client: MockClient((request) async {
            sent.add(request);
            return switch (request.url.path) {
              '/api/v1/viewer/activate' => http.Response(
                '{"refresh_token":"rt","viewer_id":"8d4b1f6e-3a2c-4d9f-a7e5-1c6b0e9f2d74","client_id":"6a0d3b1e-2f4c-4e8a-b1d7-5c9e8f2a4b60"}',
                200,
              ),
              '/api/v1/tables' => http.Response(
                '{"tables":[{"id":"t1","name":"1","number":1,"camera_online":true,"camera_last_seen_at":"2026-10-30T18:00:00Z"}]}',
                200,
              ),
              _ => http.Response(
                '{"code":"482913","expires_at":"2026-10-30T18:05:00Z","qr_payload":"{\\"v\\":1}"}',
                200,
              ),
            };
          }),
        );
        final activated = await api.activate(
          activationKey: 'KEY',
          machineId: 'm1',
          name: 'PC 1',
        );
        expect(activated.refreshToken, 'rt');
        expect(jsonDecode(sent[0].body), {
          'activation_key': 'KEY',
          'machine_id': 'm1',
          'name': 'PC 1',
        });
        final tables = await api.tables('a');
        expect(sent[1].headers['Authorization'], 'Bearer a');
        expect(tables.tables.single.cameraOnline, isTrue);
        final code = await api.pairingCode('a', 't1');
        expect(
          (sent[2].method, sent[2].url.path),
          ('POST', '/api/v1/tables/t1/pairing-code'),
        );
        expect((code.code, code.qrPayload), ('482913', '{"v":1}'));
      },
    );

    test('errors carry the status and the contract error code', () async {
      final api = ApiClient(
        'http://h',
        client: MockClient(
          (_) async => http.Response(
            '{"detail":{"code":"pairing_code_invalid","message":"no"}}',
            400,
          ),
        ),
      );
      await expectLater(
        api.pairDevice(code: '000000', model: 'm', androidId: 'a'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'pairing_code_invalid')
              .having((e) => e.status, 'status', 400),
        ),
      );
    });

    test('an unreachable server is status 0', () async {
      final api = ApiClient(
        'http://h',
        client: MockClient((_) async => throw const SocketException('down')),
      );
      await expectLater(
        api.token('r'),
        throwsA(
          isA<ApiException>().having((e) => e.unreachable, 'unreachable', true),
        ),
      );
    });
  });

  group('control socket', () {
    late HttpServer server;
    late StreamController<WebSocket> serverSockets;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverSockets = StreamController<WebSocket>();
      server.listen(
        (request) async =>
            serverSockets.add(await WebSocketTransformer.upgrade(request)),
      );
    });

    tearDown(() => server.close(force: true));

    String url() => 'ws://127.0.0.1:${server.port}/ws';

    test('a request gets its reply; other messages go to the stream', () async {
      final socket = await ControlSocket.connect(url(), 'table-1');
      final peer = await serverSockets.stream.first;
      final received = <Map<String, dynamic>>[];
      peer.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        received.add(msg);
        peer.add(
          jsonEncode({
            'type': 'stream.status',
            'id': 'x',
            'ts': 1,
            'table_id': 'table-1',
            'payload': {'status': 'live', 'since': 1},
          }),
        );
        peer.add(
          jsonEncode({
            'type': 'signaling.join.result',
            'id': 'y',
            'ts': 2,
            'table_id': 'table-1',
            'payload': {'request_id': msg['id'], 'role': 'camera'},
          }),
        );
      });
      final other = socket.messages.first;
      final reply = await socket.request('signaling.join', {'token': 't'});
      expect(reply['role'], 'camera');
      expect((await other)['type'], 'stream.status');
      expect(received.single, containsPair('table_id', 'table-1'));
      expect(received.single['payload'], {'token': 't'});
      await socket.close();
    });

    test('signaling.error fails the request with its code', () async {
      final socket = await ControlSocket.connect(url(), 't');
      final peer = await serverSockets.stream.first;
      peer.listen((data) {
        final id = (jsonDecode(data as String) as Map<String, dynamic>)['id'];
        peer.add(
          jsonEncode({
            'type': 'signaling.error',
            'id': 'e',
            'ts': 1,
            'table_id': 't',
            'payload': {
              'request_id': id,
              'code': 'license_blocked',
              'message': 'no',
            },
          }),
        );
      });
      await expectLater(
        socket.request('signaling.join', {'token': 't'}),
        throwsA(
          isA<SignalingException>().having(
            (e) => e.code,
            'code',
            'license_blocked',
          ),
        ),
      );
      await socket.close();
    });

    test(
      'the server closing fails pending requests and reports its code',
      () async {
        final socket = await ControlSocket.connect(url(), 't');
        final peer = await serverSockets.stream.first;
        final pending = socket.request('signaling.join', {'token': 't'});
        await peer.close(ControlSocket.replacedByAnotherCamera, 'replaced');
        await expectLater(pending, throwsA(isA<SocketClosedException>()));
        await socket.done;
        expect(socket.closeCode, ControlSocket.replacedByAnotherCamera);
        expect(socket.isOpen, isFalse);
      },
    );
  });

  test('log lines are JSON with the context fields', () {
    final lines = <String>[];
    final log = JsonLog(
      'camera',
      sink: lines.add,
    ).withContext({'table_id': 't1', 'session_id': 's1'});
    log.info('joined', {'role': 'camera'});
    final line = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(line, containsPair('table_id', 't1'));
    expect(line, containsPair('device_id', null));
    expect(line, containsPair('message', 'joined'));
    expect(line, containsPair('level', 'info'));
  });
}
