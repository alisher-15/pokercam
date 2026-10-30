import 'dart:convert';

import 'package:camera_android/src/app.dart';
import 'package:camera_android/src/platform/device.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

import 'fakes.dart';

/// The backend for the screens: pairing, tokens and the license.
ApiClient fakeBackend(String url, {String? pairError, String? licenseError}) =>
    ApiClient(
      url,
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/device/pair')) {
          if (pairError != null) {
            return http.Response(
              jsonEncode({
                'detail': {'code': pairError, 'message': pairError},
              }),
              400,
            );
          }
          expect(jsonDecode(request.body), {
            'code': '042137',
            'model': 'HUAWEI MatePad',
            'android_id': 'android-1',
          });
          return http.Response(
            jsonEncode({
              'refresh_token': 'r',
              'device_id': deviceId,
              'table_id': tableId,
              'client_id': pairing.clientId,
            }),
            201,
          );
        }
        if (path.endsWith('/auth/token')) {
          if (licenseError != null) {
            return http.Response(
              jsonEncode({
                'detail': {'code': licenseError, 'message': licenseError},
              }),
              403,
            );
          }
          return http.Response(
            '{"access_token":"a","token_type":"bearer","expires_in":43200,"media_url":"ws://127.0.0.1:1/ws"}',
            200,
          );
        }
        if (path.endsWith('/license')) {
          return http.Response(
            '{"status":"active","paid_until":"2026-11-28T12:00:00Z","grace_until":"2026-12-01T12:00:00Z"}',
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

Services services({
  MemoryPairings? pairings,
  String? pairError,
  String? licenseError,
  FakeDevice? device,
}) => Services(
  pairings: pairings ?? MemoryPairings(),
  settings: MemorySettings(),
  camera: FakeCamera(),
  device: device ?? FakeDevice(),
  publisher: FakePublisher(),
  log: JsonLog('camera', sink: (_) {}),
  api: (url) =>
      fakeBackend(url, pairError: pairError, licenseError: licenseError),
  scanner: (_) => const SizedBox(),
);

Future<void> pump(
  WidgetTester tester,
  Services s, {
  String locale = 'en',
}) async {
  tester.platformDispatcher.localesTestValue = [Locale(locale)];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  // A new key: each call starts the app afresh with these services.
  await tester.pumpWidget(CameraApp(key: UniqueKey(), services: s));
  await tester.pumpAndSettle();
}

Future<void> pairByHand(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.byKey(const Key('pairing-manual')), 100);
  await tester.tap(find.byKey(const Key('pairing-manual')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('pairing-server')),
    'cam.club.kz',
  );
  await tester.enterText(find.byKey(const Key('pairing-code')), '042137');
  await tester.tap(find.byKey(const Key('pairing-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an unpaired phone opens on pairing, in Russian and English', (
    tester,
  ) async {
    await pump(tester, services(), locale: 'ru');
    expect(find.text('Привязка к столу'), findsOneWidget);
    await pump(tester, services());
    expect(find.text('Pair with a table'), findsOneWidget);
  });

  testWidgets('pairing by code saves the pairing and opens the check', (
    tester,
  ) async {
    final pairings = MemoryPairings();
    await pump(tester, services(pairings: pairings));
    await pairByHand(tester);
    expect(pairings.value?.apiUrl, 'http://cam.club.kz');
    expect(pairings.value?.tableId, tableId);
    expect(find.text('Before streaming'), findsOneWidget);
  });

  testWidgets('a wrong code says so and stays on pairing', (tester) async {
    await pump(tester, services(pairError: 'pairing_code_expired'));
    await pairByHand(tester);
    expect(
      find.text('The code is wrong or has expired. Get a new one on the PC.'),
      findsOneWidget,
    );
    expect(find.text('Pair with a table'), findsOneWidget);
  });

  testWidgets(
    'a failure on the phone itself says so instead of spinning for ever',
    (tester) async {
      final pairings = MemoryPairings()
        ..saveError = Exception('KeyStoreException: Keystore operation failed');
      await pump(tester, services(pairings: pairings));
      await pairByHand(tester);
      expect(find.textContaining('Keystore operation failed'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Pair with a table'), findsOneWidget);
    },
  );

  testWidgets(
    'the check marks unsupported settings honestly and lets the paired phone start',
    (tester) async {
      await pump(tester, services(pairings: MemoryPairings(pairing)));
      expect(find.text('Before streaming'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Contrast'), 100);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Contrast'),
          matching: find.text('not supported'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'ISO'),
          matching: find.text('supported'),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('preflight-start')),
        100,
      );
      final start = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('preflight-start')),
      );
      expect(start.onPressed, isNotNull);
    },
  );

  testWidgets(
    'without camera access or with a blocked license the start button stays off',
    (tester) async {
      final device = FakeDevice()
        ..permissionsValue = const Permissions(
          camera: false,
          notifications: true,
          batteryUnrestricted: true,
        );
      await pump(
        tester,
        services(pairings: MemoryPairings(pairing), device: device),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('preflight-start')),
        100,
      );
      expect(
        tester
            .widget<ButtonStyleButton>(find.byKey(const Key('preflight-start')))
            .onPressed,
        isNull,
      );

      await pump(
        tester,
        services(
          pairings: MemoryPairings(pairing),
          licenseError: 'license_expired',
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('preflight-start')),
        100,
      );
      expect(
        tester
            .widget<ButtonStyleButton>(find.byKey(const Key('preflight-start')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('blocked'), findsOneWidget);
    },
  );
}
