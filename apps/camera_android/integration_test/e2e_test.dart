// End-to-end on the CI emulator (SPEC 6.5), driven together with tools/acceptance/stage5.ts on the host:
// the app pairs with the code the harness hands out, starts streaming, and stays up while the harness changes
// camera settings from a bot PC, cuts the network and heats the phone; at the end the harness pairs another
// camera and the app must be back on the pairing screen, told it was replaced.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:camera_android/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const harness = String.fromEnvironment('E2E_HARNESS');

Future<Map<String, dynamic>> ask(String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('$harness$path'));
    final response = await request.close();
    return jsonDecode(await response.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

/// Pumps frames until [found] shows up (the app is busy with real network and camera work meanwhile).
Future<void> waitFor(
  WidgetTester tester,
  Finder found, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (found.evaluate().isNotEmpty) return;
  }
  throw TestFailure('timed out waiting for $found');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'pairs, streams through the harness checks, and is dropped when replaced',
    (tester) async {
      expect(
        harness,
        isNotEmpty,
        reason: 'run with --dart-define=E2E_HARNESS=http://host:port',
      );
      app.main();
      await waitFor(tester, find.byKey(const Key('pairing-screen')));

      final pairing = await ask('/pairing');
      print('e2e: pairing with ${pairing['code']} at ${pairing['api']}');
      await tester.scrollUntilVisible(
        find.byKey(const Key('pairing-manual')),
        200,
      );
      await tester.tap(find.byKey(const Key('pairing-manual')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(
        find.byKey(const Key('pairing-server')),
        pairing['api'] as String,
      );
      await tester.enterText(
        find.byKey(const Key('pairing-code')),
        pairing['code'] as String,
      );
      await tester.tap(find.byKey(const Key('pairing-submit')));

      // The check's list is long: its start button is built only once scrolled to.
      await waitFor(tester, find.byKey(const Key('preflight-screen')));
      final start = find.byKey(const Key('preflight-start'));
      await tester.scrollUntilVisible(start, 200);
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (tester.widget<ButtonStyleButton>(start).onPressed == null &&
          DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(start);
      await waitFor(tester, find.byKey(const Key('broadcast-status')));
      print('e2e: streaming');

      // The harness works now; the app keeps running until it says what to expect.
      Map<String, dynamic> done = {};
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(seconds: 1));
        try {
          done = await ask('/done');
        } on Object catch (e) {
          print('e2e: harness not answering: $e');
        }
        if (done['done'] == true) break;
      }
      expect(
        done['done'],
        isTrue,
        reason: 'the harness did not finish in time',
      );
      if (done['expect'] == 'replaced') {
        await waitFor(
          tester,
          find.byKey(const Key('pairing-screen')),
          timeout: const Duration(seconds: 30),
        );
        print('e2e: back on pairing after the replacement');
      }
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
