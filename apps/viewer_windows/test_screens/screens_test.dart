// Screens of the club PC's program for the acceptance report: the real widgets with the brand's theme, fed by
// the fakes of test/. Not part of `flutter test` (it lives outside test/).
//
//   make brand BRAND=demo   # logo and icons of the brand
//   flutter test test_screens --update-goldens --dart-define-from-file=../../build/brand/demo/defines.json
//
// The PNGs land in test_screens/out/. The video is a stand-in picture: real video is in CI's screenshots.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:viewer_windows/src/app.dart';
import 'package:viewer_windows/src/store.dart';

import '../test/fakes.dart';

/// The club's PC as activated: the server at its address on the club's network.
const club = Connection(
  apiUrl: 'http://192.168.1.20:8000',
  refreshToken: 'refresh',
  viewerId: '8d4b1f6e-3a2c-4d9f-a7e5-1c6b0e9f2d74',
  clientId: '6a0d3b1e-2f4c-4e8a-b1d7-5c9e8f2a4b60',
);

const brandId = String.fromEnvironment('BRAND_ID', defaultValue: 'default');

final brand = jsonDecode(
  File('../../branding/$brandId/brand.json').readAsStringSync(),
) as Map<String, dynamic>;

/// What the seller set in the admin panel (the demo brand has its own in brand.json).
final contacts =
    (brand['seller_contacts'] as Map<String, dynamic>?) ??
    {
      'phone': '+7 701 555 12 34',
      'whatsapp': '+7 701 555 12 34',
      'telegram': '@club_support',
      'email': 'support@example.kz',
      'note': 'Ежедневно 10:00–22:00',
    };

ApiClient backend(String url, {required String mediaUrl, String? blocked}) =>
    ApiClient(
      url,
      client: MockClient((request) async {
        final path = request.url.path;
        http.Response json(Object body, [int status = 200]) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
        if (path.endsWith('/viewer/activate')) {
          return json({
            'refresh_token': 'refresh',
            'viewer_id': connection.viewerId,
            'client_id': connection.clientId,
          });
        }
        if (path.endsWith('/auth/token')) {
          if (blocked != null) {
            return json({
              'detail': {
                'code': blocked,
                'message': blocked,
                'seller_contacts': contacts,
              },
            }, 403);
          }
          return json({
            'access_token': 'access',
            'token_type': 'bearer',
            'expires_in': 43200,
            'media_url': mediaUrl,
          });
        }
        if (path.endsWith('/brand')) {
          return json({
            'app_name': brand['app_name'],
            'colors': brand['colors'],
            'seller_contacts': contacts,
          });
        }
        if (path.endsWith('/license')) {
          return json({
            'status': 'active',
            'paid_until': '2026-12-21T12:00:00Z',
            'grace_until': '2026-12-24T12:00:00Z',
          });
        }
        if (path.endsWith('/tables')) {
          return json({
            'tables': [
              {'id': tableId, 'name': '1', 'number': 1, 'camera_online': true},
              {
                'id': '0b5e9c7a-1d2f-4e3a-8c6b-9f0a1e2d3c4b',
                'name': '2',
                'number': 2,
                'camera_online': false,
                'camera_last_seen_at': '2026-11-21T09:12:00Z',
              },
            ],
          });
        }
        if (path.contains('/pairing-code')) {
          return json({
            'code': '482913',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
            'qr_payload': jsonEncode({'v': 1, 'api': url, 'code': '482913'}),
          });
        }
        return json({
          'detail': {'code': 'not_found', 'message': path},
        }, 404);
      }),
    );

/// The camera's picture: a stand-in, a felt with a few cards.
class FeltStandIn extends StatelessWidget {
  const FeltStandIn({super.key});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: RadialGradient(
        colors: [Color(0xFF2E7D4F), Color(0xFF14432A)],
        radius: 0.9,
      ),
    ),
    child: Stack(
      children: [
        for (final (x, y, r) in [
          (0.38, 0.45, -0.12),
          (0.46, 0.44, 0.05),
          (0.54, 0.45, 0.1),
          (0.62, 0.46, -0.04),
          (0.70, 0.45, 0.08),
        ])
          Align(
            alignment: Alignment(x * 2 - 1, y * 2 - 1),
            child: Transform.rotate(
              angle: r,
              child: Container(
                width: 70,
                height: 98,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.black26),
                ),
              ),
            ),
          ),
        const Positioned(
          right: 12,
          top: 10,
          child: Text(
            'видео с камеры (в этом снимке — заглушка)',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

String dvrPlaylist() {
  final end = DateTime.now().toUtc().subtract(
    const Duration(milliseconds: 1500),
  );
  final start = end.subtract(const Duration(seconds: 600));
  return [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:2',
    '#EXT-X-MEDIA-SEQUENCE:500',
    '#EXT-X-DISCONTINUITY-SEQUENCE:0',
    for (var i = 0; i < 600; i++) ...[
      '#EXT-X-PROGRAM-DATE-TIME:${start.add(Duration(seconds: i)).toIso8601String()}',
      '#EXTINF:1.000,',
      'r1/$i.ts',
    ],
  ].join('\n');
}

/// Real fonts instead of the test font (Ahem, boxes): Liberation Sans (Arial's metrics, close to Windows; it has
/// the arrows of the key hints, which Roboto lacks) when the system has it, else Flutter's Roboto; and the
/// Material icons that come with Flutter.
Future<void> loadFonts() async {
  // flutter_tester runs from <flutter>/bin/cache/artifacts/engine/<platform>/.
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent.path;
  final material = '$artifacts/material_fonts';
  const liberation = '/usr/share/fonts/truetype/liberation';
  final faces = Directory(liberation).existsSync()
      ? [
          '$liberation/LiberationSans-Regular.ttf',
          '$liberation/LiberationSans-Bold.ttf',
        ]
      : ['$material/Roboto-Regular.ttf', '$material/Roboto-Bold.ttf'];
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(File(path).readAsBytesSync());
  final sans = FontLoader('Roboto');
  for (final face in faces) {
    sans.addFont(bytes(face));
  }
  await sans.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(bytes('$material/MaterialIcons-Regular.otf'))).load();
}

void main() {
  late FakeMediaServer server;
  late MemoryStore store;

  setUpAll(() async {
    // A release build has no DEBUG ribbon.
    WidgetsApp.debugAllowBannerOverride = false;
    await loadFonts();
  });

  setUp(() async {
    server = await FakeMediaServer.start();
    store = MemoryStore();
  });

  tearDown(() => server.stop());

  Services services({String? blocked}) => Services(
    store: store,
    log: JsonLog('viewer', sink: (_) {}),
    subscriber: FakeSubscriber.new,
    api: (url) => backend(url, mediaUrl: server.url, blocked: blocked),
    connect: (url, id) => ControlSocket.connect(url, id, ping: null),
    openWindow: (id) async {},
    video: (stream) => const FeltStandIn(),
    dvrPlayer: (log) async => FakePlayer(),
    dvrGet: (url, headers) async => dvrPlaylist(),
  );

  Future<void> pump(
    WidgetTester tester,
    Services s, {
    String? initialTable,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        child: ViewerApp(
          key: UniqueKey(),
          services: s,
          initialTable: initialTable,
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> waitFor(WidgetTester tester, Finder found) async {
    for (var i = 0; i < 150 && found.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    expect(found, findsWidgets);
  }

  /// Lets the sockets and the brand request finish, then draws a settled frame.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('out/viewer-$brandId-$name.png'),
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('01 activation', (tester) async {
    await pump(tester, services());
    await tester.enterText(
      find.byKey(const Key('activation-server')),
      '192.168.1.20:8000',
    );
    await tester.enterText(
      find.byKey(const Key('activation-key')),
      'KLUB-7Q4M-2XWD',
    );
    await shot(tester, '01-activation');
  });

  testWidgets('02 tables', (tester) async {
    store.value = club;
    await pump(tester, services());
    await shot(tester, '02-tables');
  });

  testWidgets('03 pairing a phone', (tester) async {
    store.value = club;
    await pump(tester, services());
    await settle(tester);
    await tester.tap(find.byKey(const Key('table-1-pair')));
    await shot(tester, '03-pairing');
  });

  void telemetry() => server.push('device.telemetry', {
    'battery_pct': 87,
    'charging': true,
    'temp_c': 36.5,
    'thermal_status': 'light',
    'network': {
      'type': 'wifi',
      'rssi': -58,
      'rtt_ms': 12,
      'uplink_kbps': 24000,
    },
    'stream': {'bitrate_kbps': 3950, 'fps': 30, 'dropped_frames': 0},
  });

  void dvrInfo() => server.push('dvr.info', {
    'available_from': DateTime.now().millisecondsSinceEpoch - 601500,
    'available_to': DateTime.now().millisecondsSinceEpoch - 1500,
    'playlist_url': '/dvr/$tableId/index.m3u8',
  });

  testWidgets('04 live with the camera panel', (tester) async {
    store.value = club;
    await pump(tester, services(), initialTable: tableId);
    await waitFor(tester, find.byKey(const Key('watch-live')));
    telemetry();
    dvrInfo();
    await waitFor(tester, find.byKey(const Key('dvr-scale')));
    await shot(tester, '04-live');
    await close(tester);
  });

  testWidgets('05 DVR: paused 35 s back', (tester) async {
    store.value = club;
    await pump(tester, services(), initialTable: tableId);
    await waitFor(tester, find.byKey(const Key('watch-live')));
    telemetry();
    dvrInfo();
    await waitFor(tester, find.byKey(const Key('dvr-scale')));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, find.byKey(const Key('watch-behind')));
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
    }
    await shot(tester, '05-dvr');
    // Back to LIVE before closing, as the DVR test of test/ does: the window's close stops the DVR only after
    // the socket has closed, which takes real time a widget test does not give it.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await waitFor(tester, find.byKey(const Key('watch-live')));
    await close(tester);
  });

  testWidgets('06 an alert from the phone', (tester) async {
    store.value = club;
    await pump(tester, services(), initialTable: tableId);
    await waitFor(tester, find.byKey(const Key('watch-live')));
    telemetry();
    server.push('device.alert', {
      'kind': 'overheating',
      'level': 'critical',
      'message_key': 'alertOverheatingCritical',
    });
    await waitFor(tester, find.byType(SnackBar));
    await shot(tester, '06-alert');
    await close(tester);
  });

  testWidgets('07 grace: the banner with the seller', (tester) async {
    store.value = club;
    await pump(tester, services(), initialTable: tableId);
    await waitFor(tester, find.byKey(const Key('watch-live')));
    telemetry();
    server.push('license.status', {
      'status': 'grace',
      'grace_until': DateTime.now()
          .add(const Duration(days: 2, hours: 5))
          .millisecondsSinceEpoch,
    });
    await waitFor(tester, find.byKey(const Key('seller-contacts')));
    await shot(tester, '07-grace');
    await close(tester);
  });

  testWidgets('08 blocked: whom to call', (tester) async {
    store.value = club;
    await pump(
      tester,
      services(blocked: 'license_expired'),
      initialTable: tableId,
    );
    await waitFor(tester, find.byKey(const Key('seller-contacts')));
    await shot(tester, '08-blocked');
    await close(tester);
  });
}
