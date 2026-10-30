// End to end on a Windows runner (SPEC 12, stage 6: the camera is controlled from the PC), driven together
// with tools/acceptance/stage6.ts: the real app activates with the club's key the harness hands out, opens the
// table, plays the fake camera, changes the zoom and gets the camera's answer, and shows a pairing code. Its
// findings go back to the harness, which adds what the camera saw.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:viewer_windows/main.dart' as app;
import 'package:viewer_windows/src/store.dart';

const harness = String.fromEnvironment('E2E_HARNESS');

Future<Map<String, dynamic>> call(String path, {Object? body}) async {
  final client = HttpClient();
  try {
    final request = body == null
        ? await client.getUrl(Uri.parse('$harness$path'))
        : await client.postUrl(Uri.parse('$harness$path'));
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    return jsonDecode(await response.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

/// Pumps frames until [found] shows up (the app works with real sockets and WebRTC meanwhile).
Future<Duration> waitFor(
  WidgetTester tester,
  Finder found, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 200));
    if (found.evaluate().isNotEmpty) return watch.elapsed;
  }
  throw TestFailure('timed out waiting for $found');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('activates, plays the table, controls the camera, pairs a phone', (
    tester,
  ) async {
    expect(harness, isNotEmpty, reason: 'run with --dart-define=E2E_HARNESS=');
    final checks = <Map<String, Object>>[];
    void check(String name, bool ok, String detail) {
      checks.add({'check': name, 'ok': ok, 'detail': detail});
      print('e2e: ${ok ? 'PASS' : 'FAIL'} $name: $detail');
    }

    try {
      // A clean start: no connection left from an earlier run on this machine.
      await SecureConnectionStore().clear();
      app.main([]);
      await waitFor(tester, find.byKey(const Key('activation-screen')));
      final setup = await call('/setup');
      await tester.enterText(
        find.byKey(const Key('activation-server')),
        setup['api'] as String,
      );
      await tester.enterText(
        find.byKey(const Key('activation-key')),
        setup['key'] as String,
      );
      await tester.tap(find.byKey(const Key('activation-submit')));
      final activated = await waitFor(
        tester,
        find.byKey(const Key('table-1-open')),
      );
      check(
        'activation with the club key → tables',
        true,
        '${activated.inMilliseconds} ms',
      );

      await tester.tap(find.byKey(const Key('table-1-open')));
      final live = await waitFor(tester, find.byKey(const Key('watch-live')));
      // The connection line shows the decoded size once frames arrive.
      final decoded = find.textContaining(RegExp(r'[1-9]\d*×[1-9]\d*'));
      await waitFor(tester, decoded);
      final line = tester.widget<Text>(decoded.first).data ?? '';
      check(
        'the table plays live',
        true,
        '${live.inMilliseconds} ms to LIVE; $line',
      );

      // The fake camera offers zoom (manual only) and ISO (auto/manual); contrast and the rest are not supported.
      final zoom = find.byKey(const Key('param-zoom'));
      await waitFor(tester, zoom);
      await tester.ensureVisible(zoom);
      await tester.drag(
        find.descendant(of: zoom, matching: find.byType(Slider)),
        const Offset(80, 0),
      );
      final applied = find.descendant(
        of: zoom,
        matching: find.byKey(const Key('applied')),
      );
      await waitFor(tester, applied, timeout: const Duration(seconds: 10));
      check(
        'zoom from the PC, answered by the camera',
        true,
        tester.widget<Text>(applied).data ?? '',
      );
      final contrast = find.byKey(const Key('param-contrast'));
      await tester.ensureVisible(contrast);
      check(
        'unsupported settings are inactive',
        find
            .descendant(of: contrast, matching: find.byType(Tooltip))
            .evaluate()
            .isNotEmpty,
        'contrast',
      );

      await tester.tap(find.byKey(const Key('watch-pair')));
      final code = find.byKey(const Key('pairing-code'));
      await waitFor(tester, code, timeout: const Duration(seconds: 15));
      final digits = tester.widget<SelectableText>(code).data ?? '';
      check(
        'pairing code with its QR',
        RegExp(r'^\d{6}$').hasMatch(digits) &&
            find.byKey(const Key('pairing-qr')).evaluate().isNotEmpty,
        digits,
      );
    } on Object catch (e) {
      check('the run completed', false, '$e');
    } finally {
      await call('/done', body: {'checks': checks});
    }
    expect(checks.every((c) => c['ok'] == true), isTrue);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
