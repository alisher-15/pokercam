// Screens of the camera app for the acceptance report: the real widgets with the brand's theme, fed by the
// fakes of test/. Not part of `flutter test` (it lives outside test/).
//
//   make brand BRAND=demo
//   flutter test test_screens --update-goldens --dart-define-from-file=../../build/brand/demo/defines.json
//
// The PNGs land in test_screens/out/. The broadcast itself is in CI's emulator screenshots.
import 'dart:convert';
import 'dart:io';

import 'package:camera_android/src/app.dart';
import 'package:camera_android/src/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

import '../test/fakes.dart';

const brandId = String.fromEnvironment('BRAND_ID', defaultValue: 'default');

final brand = jsonDecode(
  File('../../branding/$brandId/brand.json').readAsStringSync(),
) as Map<String, dynamic>;

final contacts =
    (brand['seller_contacts'] as Map<String, dynamic>?) ??
    {
      'phone': '+7 701 555 12 34',
      'whatsapp': '+7 701 555 12 34',
      'telegram': '@club_support',
      'note': 'Ежедневно 10:00–22:00',
    };

const paired = Pairing(
  apiUrl: 'http://192.168.1.20:8000',
  refreshToken: 'refresh',
  deviceId: deviceId,
  tableId: tableId,
  clientId: '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f80',
);

ApiClient backend(String url, {String? blocked}) => ApiClient(
  url,
  client: MockClient((request) async {
    final path = request.url.path;
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
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
        'access_token': 'a',
        'token_type': 'bearer',
        'expires_in': 43200,
        'media_url': 'ws://127.0.0.1:1/ws',
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
    return json({}, 404);
  }),
);

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

Services services({MemoryPairings? pairings, String? blocked}) => Services(
  pairings: pairings ?? MemoryPairings(),
  settings: MemorySettings(),
  camera: FakeCamera(),
  device: FakeDevice(),
  publisher: FakePublisher(),
  log: JsonLog('camera', sink: (_) {}),
  api: (url) => backend(url, blocked: blocked),
  scanner: (_) => const ColoredBox(
    color: Color(0xFF1F2A24),
    child: Center(
      child: Text(
        'камера телефона: сюда наводят QR с ПК\n(в этом снимке — заглушка)',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white54),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    WidgetsApp.debugAllowBannerOverride = false;
    await loadFonts();
  });

  Future<void> pump(WidgetTester tester, Services s) async {
    tester.platformDispatcher.localesTestValue = [const Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    // A 6.5" phone: 412 x 915 dp.
    tester.view.physicalSize = const Size(824, 1830);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        child: CameraApp(key: UniqueKey(), services: s),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('out/camera-$brandId-$name.png'),
    );
  }

  testWidgets('01 pairing by QR', (tester) async {
    await pump(tester, services());
    await shot(tester, '01-pairing');
  });

  testWidgets('02 pairing by hand', (tester) async {
    await pump(tester, services());
    await tester.scrollUntilVisible(
      find.byKey(const Key('pairing-manual')),
      100,
    );
    await tester.tap(find.byKey(const Key('pairing-manual')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pairing-server')),
      '192.168.1.20:8000',
    );
    await tester.enterText(find.byKey(const Key('pairing-code')), '482913');
    await tester.pump();
    await shot(tester, '02-pairing-code');
  });

  testWidgets('03 the check before streaming', (tester) async {
    await pump(tester, services(pairings: MemoryPairings(paired)));
    await shot(tester, '03-preflight');
    await tester.scrollUntilVisible(
      find.byKey(const Key('preflight-start')),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await shot(tester, '04-preflight-bottom');
  });

  testWidgets('05 blocked: the check says whom to call', (tester) async {
    await pump(
      tester,
      services(pairings: MemoryPairings(paired), blocked: 'license_expired'),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('seller-contacts')),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await shot(tester, '05-blocked');
  });
}
