import 'package:camera_android/src/platform/device.dart';
import 'package:camera_android/src/media.dart';
import 'package:camera_android/src/session.dart';
import 'package:camera_android/src/tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

import 'fakes.dart';

void main() {
  late FakeMediaServer server;
  late FakePublisher publisher;
  late FakeCamera camera;
  late FakeDevice device;
  late MemorySettings settings;
  final logs = <String>[];

  setUp(() async {
    server = await FakeMediaServer.start();
    publisher = FakePublisher();
    camera = FakeCamera();
    device = FakeDevice();
    settings = MemorySettings();
    logs.clear();
  });

  tearDown(() => server.stop());

  BroadcastSession session({int tokenStatus = 200}) => BroadcastSession(
    pairing: pairing,
    tokens: TokenSource(backend(server.url, status: tokenStatus), 'refresh'),
    publisher: publisher,
    camera: camera,
    device: device,
    settings: settings,
    log: JsonLog('camera', sink: logs.add),
    telemetryEvery: const Duration(milliseconds: 200),
    blockedRetry: const Duration(milliseconds: 200),
    backoff: Backoff([const Duration(milliseconds: 50)]),
  );

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue);
  }

  test('joins with the access token, publishes, then tells the room what the camera can do', () async {
    final s = session();
    final run = s.run();
    final join = await server.next('signaling.join');
    expect(join['payload'], {'token': 'access'});
    expect(join['table_id'], tableId);
    final caps = await server.next('camera.capabilities');
    expect((caps['payload']['params'] as Map)['contrast'], {
      'supported': false,
      'modes': [],
      'presets': [],
    });
    final state = await server.next('camera.state');
    expect(
      state['payload']['controls'],
      containsPair('zoom', {'mode': 'manual', 'value': 1.0}),
    );
    expect(publisher.bitrates.first, 4000000);
    await until(() => s.state.phase == SessionPhase.live);
    await s.stop();
    expect(await run, SessionPhase.stopped);
  });

  test('camera.set: applied, acknowledged to its request, saved, and the new state sent', () async {
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    final seen = server.received.length;
    final id = server.push('camera.set', {
      'param': 'iso',
      'control': {'mode': 'manual', 'value': 6400},
    });
    final ack = await server.next('camera.ack', after: seen);
    expect(ack['payload'], {
      'request_id': id,
      'ok': true,
      'applied': {'mode': 'manual', 'value': 3200.0},
    });
    final state = await server.next('camera.state', after: seen);
    expect(
      state['payload']['controls'],
      containsPair('iso', {'mode': 'manual', 'value': 3200.0}),
    );
    expect(settings.values['iso']?.value, 3200);

    final refused = server.push('camera.set', {
      'param': 'contrast',
      'control': {'mode': 'manual', 'value': 10},
    });
    final no = await server.next(
      'camera.ack',
      where: (p) => p['request_id'] == refused,
    );
    expect(no['payload'], {
      'request_id': refused,
      'ok': false,
      'error': 'unsupported_param',
    });
    await s.stop();
    await run;
  });

  test('a lost connection: reconnects, publishes again and restores the saved settings', () async {
    settings.values['focus'] = CameraControl(
      mode: ControlMode.MANUAL,
      value: 2,
    );
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    expect(camera.applied.single, containsPair('focus', isA<CameraControl>()));
    await server.closeLatest();
    await until(() => server.joins == 2 && publisher.published == 2);
    expect(publisher.unpublished, greaterThanOrEqualTo(1));
    expect(camera.applied, hasLength(2));
    await until(() => s.state.phase == SessionPhase.live);
    await s.stop();
    await run;
  });

  test('the transport failing (network gone) also reconnects', () async {
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    publisher.fail();
    await until(() => server.joins == 2);
    await s.stop();
    await run;
  });

  test('the camera taken away (no capture session): reopened, then published again', () async {
    camera.lostTracks.add('track-1');
    final s = session();
    final run = s.run();
    await server.next('camera.capabilities');
    expect(publisher.closed, 1);
    expect(publisher.opened, 2);
    expect(server.joins, 2);
    await until(() => s.state.phase == SessionPhase.live);
    expect(
      logs.any((l) => l.contains('"message":"reopening the camera"')),
      isTrue,
    );
    await s.stop();
    await run;
  });

  test('a camera that sends nothing while published is reopened (SPEC 6.4: the stream recovers on its own)', () async {
    publisher.statsValue = const PublishStats(
      bitrateKbps: 0,
      fps: 0,
      droppedFrames: 3,
    );
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    await until(() => publisher.opened == 2 && server.joins == 2);
    expect(publisher.closed, 1);
    expect(
      logs.any((l) => l.contains('"message":"camera stalled: nothing sent"')),
      isTrue,
    );
    publisher.statsValue = const PublishStats(
      bitrateKbps: 3900,
      fps: 30,
      droppedFrames: 0,
    );
    await until(() => s.state.phase == SessionPhase.live);
    await s.stop();
    await run;
  });

  test('replaced by another camera (close 4001): back to pairing', () async {
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    await server.closeLatest(ControlSocket.replacedByAnotherCamera);
    expect(
      await run.timeout(const Duration(seconds: 5)),
      SessionPhase.unpaired,
    );
  });

  test('revoked in the admin panel (token 401): back to pairing', () async {
    final s = session(tokenStatus: 401);
    expect(
      await s.run().timeout(const Duration(seconds: 5)),
      SessionPhase.unpaired,
    );
  });

  test('a blocked license stops publishing; when it is back the camera publishes again', () async {
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    server.push('license.status', {'status': 'blocked'});
    await until(
      () => s.state.phase == SessionPhase.blocked && publisher.unpublished >= 1,
    );
    final seen = server.received.length;
    server.push('license.status', {
      'status': 'grace',
      'grace_until': 1793500000000,
    });
    await server.next('camera.capabilities', after: seen);
    expect(publisher.published, 2);
    await until(() => s.state.phase == SessionPhase.live);
    expect(s.state.license, RoomLicenseStatus.GRACE);
    expect(
      s.state.graceUntil,
      DateTime.fromMillisecondsSinceEpoch(1793500000000),
    );
    await s.stop();
    await run;
  });

  test('a join refused for the license retries until it is back', () async {
    server.refuseJoin = 'license_blocked';
    final s = session();
    final run = s.run();
    await until(() => s.state.phase == SessionPhase.blocked);
    server.refuseJoin = null;
    await server.next('camera.capabilities');
    await until(() => s.state.phase == SessionPhase.live);
    await s.stop();
    await run;
  });

  test('telemetry every period; heat lowers the bitrate and alerts the room (SPEC 6.4)', () async {
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    final telemetry = await server.next('device.telemetry');
    expect(telemetry['payload'], {
      'battery_pct': 80,
      'charging': true,
      'temp_c': 31.5,
      'thermal_status': 'none',
      'network': {'type': 'wifi', 'rssi': -55, 'rtt_ms': 12},
      'stream': {'bitrate_kbps': 3900, 'fps': 30.0, 'dropped_frames': 2},
    });
    device.snapshotValue = DeviceSnapshot(
      batteryPct: 80,
      charging: true,
      tempC: 31.5,
      thermal: ThermalStatus.SEVERE,
      network: NetworkInfo(type: NetworkType.WIFI),
    );
    final alert = await server.next('device.alert');
    expect(alert['payload'], {
      'kind': 'overheating',
      'level': 'critical',
      'message_key': 'alertOverheatingCritical',
    });
    expect(publisher.bitrates.last, 2000000);
    await until(
      () => s.state.banners.any(
        (a) => a.messageKey == 'alertOverheatingCritical',
      ),
    );
    await s.stop();
    await run;
  });

  test('every log line carries the table, the device and, once joined, the session', () async {
    final s = session();
    final run = s.run();
    await server.next('camera.state');
    await s.stop();
    await run;
    final joined = logs.firstWhere((l) => l.contains('"message":"joined"'));
    expect(joined, contains('"table_id":"$tableId"'));
    expect(joined, contains('"device_id":"$deviceId"'));
    expect(
      joined,
      contains('"session_id":"00000000-0000-4000-8000-000000000001"'),
    );
  });
}
