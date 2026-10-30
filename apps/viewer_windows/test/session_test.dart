import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';
import 'package:viewer_windows/src/session.dart';
import 'package:viewer_windows/src/store.dart';

import 'fakes.dart';

void main() {
  late FakeMediaServer server;
  late FakeSubscriber subscriber;
  final logs = <String>[];

  setUp(() async {
    server = await FakeMediaServer.start();
    subscriber = FakeSubscriber();
    logs.clear();
  });

  tearDown(() => server.stop());

  TableSession session({int tokenStatus = 200}) {
    final api = fakeBackend(
      'http://backend',
      mediaUrl: server.url,
      tokenStatus: tokenStatus,
    );
    return TableSession(
      tableId: tableId,
      tokens: (id) => api.token('refresh', tableId: id),
      subscriber: subscriber,
      log: JsonLog('viewer', sink: logs.add),
      statsEvery: const Duration(milliseconds: 50),
      blockedRetry: const Duration(milliseconds: 200),
      ackTimeout: const Duration(milliseconds: 300),
      backoff: Backoff([const Duration(milliseconds: 50)]),
    );
  }

  Future<void> until(TableSession s, bool Function(WatchState) done) async {
    for (var i = 0; i < 100 && !done(s.state); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(done(s.state), isTrue, reason: 'phase ${s.state.phase}');
  }

  test('joins the table with its token and plays the camera announced in the welcome', () async {
    final s = session();
    final run = s.run();
    final join = await server.next('signaling.join');
    expect(join['payload'], {'token': 'access'});
    expect(join['table_id'], tableId);
    await until(s, (st) => st.phase == WatchPhase.live && st.receive != null);
    expect(subscriber.consumed, 1);
    expect(s.state.license, RoomLicenseStatus.ACTIVE);
    expect(s.state.receive?.width, 1920);
    expect(s.state.capabilities?.focus.supported, isTrue);
    expect(s.state.controls[CameraParam.ISO]?.value, 400);
    await s.stop();
    expect(await run, WatchPhase.stopped);
  });

  test('camera.set completes with the camera\'s answer; the new state comes in camera.state', () async {
    final s = session();
    final run = s.run();
    await until(s, (st) => st.phase == WatchPhase.live);
    final ok = await s.set(
      CameraParam.FOCUS,
      CameraControl(mode: ControlMode.MANUAL, value: 2.5),
    );
    expect((ok.ok, ok.applied?.value), (true, 2.5));
    final sent = await server.next('camera.set');
    expect(sent['payload'], {
      'param': 'focus',
      'control': {'mode': 'manual', 'value': 2.5},
    });
    await until(s, (st) => st.controls[CameraParam.FOCUS]?.value == 2.5);

    server.ackError = 'out_of_range';
    final refused = await s.set(
      CameraParam.ISO,
      CameraControl(mode: ControlMode.MANUAL, value: 9999),
    );
    expect((refused.ok, refused.error), (false, CameraErrorCode.OUT_OF_RANGE));

    server.answerSets = false;
    final silent = await s.set(
      CameraParam.FOCUS,
      CameraControl(mode: ControlMode.AUTO),
    );
    expect((silent.ok, silent.error), (false, null));
    await s.stop();
    await run;
  });

  test('a lost connection: reconnects, joins again and plays the camera again (SPEC 8.5)', () async {
    final s = session();
    final run = s.run();
    await until(s, (st) => st.phase == WatchPhase.live);
    await server.closeLatest();
    await until(s, (st) => server.joins == 2 && st.phase == WatchPhase.live);
    expect(subscriber.consumed, 2);
    expect(subscriber.closed, greaterThanOrEqualTo(1));
    await s.stop();
    await run;
  });

  test('the receive transport failing also reconnects', () async {
    final s = session();
    final run = s.run();
    await until(s, (st) => st.phase == WatchPhase.live);
    subscriber.fail();
    await until(s, (_) => server.joins == 2);
    await s.stop();
    await run;
  });

  test('the camera offline: waiting, with the time it went offline; back when it publishes', () async {
    server.cameraLive = false;
    final s = session();
    final run = s.run();
    await until(
      s,
      (st) => st.phase == WatchPhase.waiting && st.cameraOfflineSince != null,
    );
    expect(
      s.state.cameraOfflineSince,
      DateTime.fromMillisecondsSinceEpoch(1793500000000),
    );
    server.push('stream.status', {'status': 'live', 'since': 1793500100000});
    server.push('signaling.new_producer', {
      'producer_id': 'p2',
      'kind': 'video',
    });
    await until(s, (st) => st.phase == WatchPhase.live);
    expect(s.state.cameraOfflineSince, isNull);
    server.push('signaling.consumer_closed', {'consumer_id': 'c1'});
    await until(s, (st) => st.phase == WatchPhase.waiting && st.stream == null);
    await s.stop();
    await run;
  });

  test('license: grace keeps the video with its date, blocked replaces it (SPEC 8.4)', () async {
    final s = session();
    final run = s.run();
    await until(s, (st) => st.phase == WatchPhase.live);
    server.push('license.status', {
      'status': 'grace',
      'grace_until': 1793500000000,
    });
    await until(s, (st) => st.license == RoomLicenseStatus.GRACE);
    expect(
      s.state.graceUntil,
      DateTime.fromMillisecondsSinceEpoch(1793500000000),
    );
    expect(s.state.phase, WatchPhase.live);
    server.push('license.status', {'status': 'blocked'});
    await until(s, (st) => st.phase == WatchPhase.blocked);
    await s.stop();
    await run;
  });

  test('a full room and a refused license wait and try again', () async {
    server.refuseJoin = 'room_full';
    final s = session();
    final run = s.run();
    await until(s, (st) => st.phase == WatchPhase.roomFull);
    server.refuseJoin = 'license_blocked';
    await until(s, (st) => st.phase == WatchPhase.blocked);
    server.refuseJoin = null;
    await until(s, (st) => st.phase == WatchPhase.live);
    await s.stop();
    await run;
  });

  test(
    'revoked in the admin panel (token 401): this PC must activate again',
    () async {
      final s = session(tokenStatus: 401);
      expect(
        await s.run().timeout(const Duration(seconds: 5)),
        WatchPhase.unauthorized,
      );
    },
  );

  test('alerts: each one as it comes, and the journal keeps the last 50, newest first', () async {
    final s = session();
    final run = s.run();
    await until(s, (st) => st.phase == WatchPhase.live);
    final first = s.alerts.first;
    for (var i = 0; i < 52; i++) {
      server.push('device.alert', {
        'kind': 'overheating',
        'level': i == 51 ? 'critical' : 'warning',
        'message_key': 'alertOverheating',
      });
    }
    expect((await first).kind, AlertKind.OVERHEATING);
    await until(s, (st) => st.alerts.length == 50);
    expect(s.state.alerts.first.level, AlertLevel.CRITICAL);
    server.push('device.telemetry', {
      'battery_pct': 34,
      'charging': false,
      'temp_c': 31,
      'thermal_status': 'none',
      'network': {'type': 'wifi', 'rssi': -72, 'rtt_ms': 4},
      'stream': {'bitrate_kbps': 4010, 'fps': 25, 'dropped_frames': 7},
    });
    await until(s, (st) => st.telemetry?.batteryPct == 34);
    await s.stop();
    await run;
  });

  test(
    'every log line carries the table and, once joined, the session',
    () async {
      final s = session();
      final run = s.run();
      await until(s, (st) => st.phase == WatchPhase.live);
      await s.stop();
      await run;
      final joined = logs.firstWhere((l) => l.contains('"message":"joined"'));
      expect(joined, contains('"table_id":"$tableId"'));
      expect(
        joined,
        contains('"session_id":"00000000-0000-4000-8000-000000000001"'),
      );
    },
  );

  test('MachineGuid is read from reg.exe\'s answer', () {
    expect(
      parseMachineGuid(
        '\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F\r\n',
      ),
      '1d2e3f40-5a6b-4c7d-8e9f-0a1b2c3d4e5f',
    );
    expect(parseMachineGuid('ERROR: not found'), isNull);
  });
}
