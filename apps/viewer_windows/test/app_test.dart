import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';
import 'package:viewer_windows/src/app.dart';

import 'fakes.dart';

void main() {
  late FakeMediaServer server;
  late MemoryStore store;
  late List<String> windows;
  late List<http.Request> sent;

  setUp(() async {
    server = await FakeMediaServer.start();
    store = MemoryStore();
    windows = [];
    sent = [];
  });

  tearDown(() => server.stop());

  Services services({String? activationError, int tokenStatus = 200}) =>
      Services(
        store: store,
        log: JsonLog('viewer', sink: (_) {}),
        subscriber: FakeSubscriber.new,
        api: (url) => fakeBackend(
          url,
          mediaUrl: server.url,
          activationError: activationError,
          tokenStatus: tokenStatus,
          sent: sent,
        ),
        connect: (url, id) => ControlSocket.connect(url, id, ping: null),
        openWindow: (id) async => windows.add(id),
        video: (stream) =>
            ColoredBox(key: Key('video-${stream.id}'), color: Colors.black),
      );

  Future<void> pump(
    WidgetTester tester,
    Services s, {
    String locale = 'en',
    String? initialTable,
  }) async {
    tester.platformDispatcher.localesTestValue = [Locale(locale)];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ViewerApp(key: UniqueKey(), services: s, initialTable: initialTable),
    );
    // The watch screen spins until it is connected: no settling there, a few frames instead.
    if (initialTable == null) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  /// Real sockets: lets them work, then draws, until [found] shows up.
  Future<void> waitFor(WidgetTester tester, Finder found) async {
    for (var i = 0; i < 100 && found.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    expect(found, findsWidgets);
  }

  /// Closes the app and lets its sockets and timers finish.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(seconds: 5));
  }

  Future<void> activate(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('activation-server')),
      'cam.club.kz:8000',
    );
    await tester.enterText(find.byKey(const Key('activation-key')), 'KEY-1');
    await tester.tap(find.byKey(const Key('activation-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('a new PC opens on activation, in Russian and English', (
    tester,
  ) async {
    await pump(tester, services(), locale: 'ru');
    expect(find.text('Подключение компьютера'), findsOneWidget);
    await pump(tester, services());
    expect(find.text('Connect this computer'), findsOneWidget);
  });

  testWidgets(
    'activation saves the connection and lists the tables with their cameras',
    (tester) async {
      await pump(tester, services());
      await activate(tester);
      expect(store.value?.apiUrl, 'http://cam.club.kz:8000');
      expect(store.value?.refreshToken, 'refresh');
      expect(
        sent.first.url.toString(),
        'http://cam.club.kz:8000/api/v1/viewer/activate',
      );
      expect(find.text('Table 1'), findsOneWidget);
      expect(find.text('camera on air'), findsOneWidget);
      expect(find.textContaining('camera last seen'), findsOneWidget);
    },
  );

  testWidgets('a wrong key says so and stays on activation', (tester) async {
    await pump(tester, services(activationError: 'invalid_activation_key'));
    await activate(tester);
    expect(find.text('Wrong activation key.'), findsOneWidget);
    expect(store.value, isNull);
  });

  testWidgets('pair a phone: the QR code and the 6-digit code (SPEC 8.1)', (
    tester,
  ) async {
    store.value = connection;
    await pump(tester, services());
    await tester.tap(find.byKey(const Key('table-1-pair')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pairing-qr')), findsOneWidget);
    expect(find.text('482913'), findsOneWidget);
    expect(find.text('Server: http://backend'), findsOneWidget);
  });

  testWidgets(
    'another table opens in a new window (SPEC 8: one window per table)',
    (tester) async {
      store.value = connection;
      await pump(tester, services());
      await tester.tap(find.byKey(const Key('table-1-window')));
      expect(windows, [tableId]);
    },
  );

  testWidgets(
    'the table live: LIVE, the panel built from the camera, unsupported inactive',
    (tester) async {
      store.value = connection;
      await pump(tester, services(), initialTable: tableId);
      await waitFor(tester, find.byKey(const Key('watch-live')));
      expect(find.byKey(const Key('video-stream-1')), findsOneWidget);
      await waitFor(tester, find.byKey(const Key('param-focus')));
      final contrast = find.byKey(const Key('param-contrast'));
      expect(
        find.descendant(of: contrast, matching: find.text('not supported')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: contrast, matching: find.byType(Tooltip)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('param-iso')),
          matching: find.byKey(const Key('slider')),
        ),
        findsOneWidget,
      );
      await close(tester);
    },
  );

  testWidgets(
    'a slider sends camera.set 100 ms after it stops; a refusal puts it back with a toast (SPEC 8.4)',
    (tester) async {
      store.value = connection;
      await pump(tester, services(), initialTable: tableId);
      await waitFor(tester, find.byKey(const Key('param-iso')));
      final iso = find.byKey(const Key('param-iso'));
      final slider = find.descendant(of: iso, matching: find.byType(Slider));

      await tester.drag(slider, const Offset(200, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(server.received.where((m) => m['type'] == 'camera.set'), isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      await waitFor(
        tester,
        find.descendant(of: iso, matching: find.byKey(const Key('applied'))),
      );
      final set = await tester.runAsync(() => server.next('camera.set'));
      expect(set!['payload']['param'], 'iso');
      final sentValue = (set['payload']['control']['value'] as num).toDouble();
      expect(sentValue, greaterThan(400));

      server.ackError = 'out_of_range';
      await tester.drag(slider, const Offset(-300, 0));
      await tester.pump(const Duration(milliseconds: 150));
      await waitFor(tester, find.textContaining('out_of_range'));
      expect(tester.widget<Slider>(slider).value, sentValue);
      await close(tester);
    },
  );

  testWidgets('alerts pop up and go into the journal', (tester) async {
    store.value = connection;
    await pump(tester, services(), initialTable: tableId);
    await waitFor(tester, find.byKey(const Key('watch-live')));
    server.push('device.alert', {
      'kind': 'overheating',
      'level': 'critical',
      'message_key': 'alertOverheatingCritical',
    });
    await waitFor(tester, find.byKey(const Key('alert-journal')));
    expect(find.textContaining('badly overheated'), findsWidgets);
    expect(find.byType(SnackBar), findsOneWidget);
    await close(tester);
  });

  testWidgets('revoked in the admin panel: back to activation, saying why', (
    tester,
  ) async {
    store.value = connection;
    await pump(tester, services(tokenStatus: 401), initialTable: tableId);
    await waitFor(tester, find.byKey(const Key('activation-screen')));
    expect(
      find.text(
        'This computer was disconnected in the admin panel. Connect it again.',
      ),
      findsOneWidget,
    );
    expect(store.value, isNull);
  });
}
