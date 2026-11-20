// End to end on a Windows runner (SPEC 12, stages 6 and 7), driven together with tools/acceptance/stage6.ts:
// the real app activates with the club's key the harness hands out, opens the table, plays the fake camera,
// changes the zoom and gets the camera's answer, rewinds the DVR media-server records with every key of SPEC
// 8.3 (measuring how far each lands from where it should and how long the picture is black on the way into
// and out of the DVR), and shows a pairing code. With SOAK_MINUTES it then keeps rewinding for that long and
// reports its memory (SPEC 8.6). Its findings go back to the harness, which adds what the camera saw.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:viewer_windows/main.dart' as app;
import 'package:viewer_windows/src/dvr/controller.dart';
import 'package:viewer_windows/src/store.dart';
import 'package:viewer_windows/src/ui/watch_screen.dart';

const harness = String.fromEnvironment('E2E_HARNESS');
const soakMinutes = int.fromEnvironment('SOAK_MINUTES');

/// SPEC 8.6: a key lands at most this far from where it should; the picture is black at most this long.
const tolerance = Duration(milliseconds: 100);
const maxBlack = Duration(milliseconds: 300);

/// Mean brightness (0–255) of the video area below this is a black screen.
const darkBelow = 6.0;

Future<Map<String, dynamic>> call(String path, {Object? body}) async {
  final client = HttpClient();
  try {
    final request = body == null
        ? await client.getUrl(Uri.parse('$harness$path'))
        : await client.postUrl(Uri.parse('$harness$path'));
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
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

/// The video area's mean brightness, on a small copy of what is drawn there.
Future<double> brightness(WidgetTester tester) async {
  final area = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('video-area')),
  );
  final image = await area.toImage(pixelRatio: 0.1);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (data == null) return 0;
  var sum = 0;
  for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
    sum += data.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2);
  }
  return sum / 3 / (data.lengthInBytes / 4);
}

/// Presses [key] (with Shift when asked) and watches the picture until [done] plus a second: how long it took
/// and the longest time the video area was black.
Future<Map<String, Object>> press(
  WidgetTester tester,
  LogicalKeyboardKey key,
  bool Function() done, {
  bool shift = false,
}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  final watch = Stopwatch()..start();
  int? doneMs;
  Duration? darkSince;
  var longestDark = 0;
  var darkest = 255.0;
  while (watch.elapsed < const Duration(seconds: 20)) {
    await tester.pump(const Duration(milliseconds: 16));
    final b = await brightness(tester);
    darkest = math.min(darkest, b);
    if (b < darkBelow) {
      darkSince ??= watch.elapsed;
      longestDark = math.max(
        longestDark,
        (watch.elapsed - darkSince).inMilliseconds,
      );
    } else {
      darkSince = null;
    }
    if (doneMs == null && done()) doneMs = watch.elapsedMilliseconds;
    if (doneMs != null && watch.elapsedMilliseconds > doneMs + 1000) break;
  }
  return {
    'ms': doneMs ?? -1,
    'longest_black_ms': longestDark,
    'darkest': darkest.round(),
  };
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

      await dvrChecks(tester, check);

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
  }, timeout: Timeout(Duration(minutes: 15 + soakMinutes)));
}

/// Stage 7 (SPEC 8.2, 8.3, 8.6): the DVR media-server records from the fake camera, through the app's keys.
Future<void> dvrChecks(
  WidgetTester tester,
  void Function(String name, bool ok, String detail) check,
) async {
  final cubit = BlocProvider.of<WatchCubit>(
    tester.element(find.byKey(const Key('watch-panel'))),
  );
  final scale = await waitFor(
    tester,
    find.byKey(const Key('dvr-scale')),
    timeout: const Duration(seconds: 90),
  );
  check('dvr.info: the DVR scale', true, '${scale.inMilliseconds} ms');
  // A buffer long enough for −10 s twice.
  final recorded = Stopwatch()..start();
  while (recorded.elapsed < const Duration(seconds: 25)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  final live = await brightness(tester);
  check(
    'the live picture can be measured',
    live >= darkBelow,
    'brightness ${live.round()}',
  );

  // Space in LIVE: the picture stops, the DVR shows that moment.
  DvrController? dvr() => cubit.dvr.value;
  final into = await press(
    tester,
    LogicalKeyboardKey.space,
    () => dvr()?.view.showing == true && dvr()?.view.live == false,
  );
  check(
    'Space: LIVE → DVR, no black screen over ${maxBlack.inMilliseconds} ms',
    into['ms'] != -1 &&
        (into['longest_black_ms']! as int) <= maxBlack.inMilliseconds,
    jsonEncode(into),
  );
  final controller = dvr();
  if (controller == null) return;

  Future<void> step(
    String name,
    LogicalKeyboardKey key,
    Duration delta, {
    bool shift = false,
  }) async {
    final before = controller.view.position!;
    final result = await press(
      tester,
      key,
      () => controller.view.position != before,
      shift: shift,
    );
    await controller.idle;
    final expected = before.add(delta);
    final shown = await controller.shown();
    final off = shown?.difference(expected).abs();
    check(
      '$name: lands within ${tolerance.inMilliseconds} ms',
      controller.view.position == expected && off != null && off <= tolerance,
      jsonEncode({...result, 'off_ms': off?.inMilliseconds}),
    );
  }

  await step('←', LogicalKeyboardKey.arrowLeft, const Duration(seconds: -1));
  await step('→', LogicalKeyboardKey.arrowRight, const Duration(seconds: 1));
  await step(
    '↓',
    LogicalKeyboardKey.arrowDown,
    const Duration(milliseconds: -500),
  );
  await step(
    '↑',
    LogicalKeyboardKey.arrowUp,
    const Duration(milliseconds: 500),
  );
  await step(
    'Shift+←',
    LogicalKeyboardKey.arrowLeft,
    const Duration(seconds: -10),
    shift: true,
  );

  // Space: playing behind in real time; Space again: paused where it got to.
  final from = controller.view.position!;
  await press(tester, LogicalKeyboardKey.space, () => !controller.view.paused);
  final playing = Stopwatch()..start();
  while (playing.elapsed < const Duration(seconds: 3)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await press(tester, LogicalKeyboardKey.space, () => controller.view.paused);
  await controller.idle;
  final at = controller.view.position!;
  final shown = await controller.shown();
  final played = at.difference(from);
  check(
    'Space: plays behind in real time, Space: pauses there',
    shown != null &&
        shown.difference(at).abs() <= tolerance &&
        played > const Duration(seconds: 2) &&
        played < const Duration(seconds: 6),
    'played ${played.inMilliseconds} ms in ${playing.elapsedMilliseconds} ms',
  );
  final behind = find.byKey(const Key('watch-behind'));
  check(
    'the yellow indicator shows how far behind',
    behind.evaluate().isNotEmpty &&
        find
            .descendant(of: behind, matching: find.textContaining('−00:'))
            .evaluate()
            .isNotEmpty,
    '',
  );

  // L: back to LIVE at once (the live video kept playing underneath).
  final back = await press(
    tester,
    LogicalKeyboardKey.keyL,
    () => controller.view.live,
  );
  check(
    'L: DVR → LIVE, no black screen over ${maxBlack.inMilliseconds} ms',
    back['ms'] != -1 &&
        (back['longest_black_ms']! as int) <= maxBlack.inMilliseconds &&
        find.byKey(const Key('watch-live')).evaluate().isNotEmpty,
    jsonEncode(back),
  );

  if (soakMinutes > 0) await soak(tester, controller, check);
}

/// SPEC 8.6 (8 hours without a leak: RSS growth under 200 MB): keeps rewinding and going LIVE for
/// [soakMinutes], with the memory of this process once a minute after a warm-up.
Future<void> soak(
  WidgetTester tester,
  DvrController controller,
  void Function(String name, bool ok, String detail) check,
) async {
  final keys = [
    (LogicalKeyboardKey.arrowLeft, true),
    (LogicalKeyboardKey.space, false),
    (LogicalKeyboardKey.arrowLeft, false),
    (LogicalKeyboardKey.arrowRight, false),
    (LogicalKeyboardKey.space, false),
    (LogicalKeyboardKey.arrowDown, false),
    (LogicalKeyboardKey.space, false),
    (LogicalKeyboardKey.keyL, false),
  ];
  final watch = Stopwatch()..start();
  const warmUp = Duration(minutes: 2);
  int? startRss;
  var maxRss = 0;
  var lastSample = Duration.zero;
  var pressed = 0;
  final samples = <int>[];
  while (watch.elapsed < Duration(minutes: soakMinutes)) {
    final (key, shift) = keys[pressed++ % keys.length];
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final pause = Stopwatch()..start();
    while (pause.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    if (watch.elapsed - lastSample >= const Duration(minutes: 1)) {
      lastSample = watch.elapsed;
      final rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      samples.add(rss);
      if (watch.elapsed >= warmUp) {
        startRss ??= rss;
        maxRss = math.max(maxRss, rss);
      }
      print('e2e: soak ${watch.elapsed.inMinutes} min, RSS $rss MB');
    }
  }
  await controller.goLive();
  final endRss = ProcessInfo.currentRss ~/ (1024 * 1024);
  final growth = endRss - (startRss ?? endRss);
  check(
    'memory over $soakMinutes min of rewinding: RSS growth under 200 MB',
    growth < 200,
    'after warm-up $startRss MB, max $maxRss MB, end $endRss MB, growth $growth MB, '
        '$pressed keys; per minute: ${samples.join(' ')}',
  );
}
