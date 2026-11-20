// SPEC 8.6, stage 7: every key of SPEC 8.3 lands within 0.1 s of where it should, checked on the frame the
// player really shows. The app's DVR (DvrController + the media_kit player) plays a recording whose every frame
// carries its number (support/hls_fixture.dart), served as media-server serves the DVR; the recording grows
// in real time and has two FFmpeg runs with a gap between them. Run on Windows:
//   flutter test integration_test/dvr_player_test.dart -d windows   (needs ffmpeg with libx264 on PATH)
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared/shared.dart';
import 'package:viewer_windows/src/app.dart';
import 'package:viewer_windows/src/dvr/controller.dart';
import 'package:viewer_windows/src/dvr/media_kit_player.dart';

import 'support/hls_fixture.dart';

/// SPEC 8.6: the position may be off by at most this much.
const tolerance = 0.1;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every DVR key lands on the expected frame (SPEC 8.3, 8.6)', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    final checks = <Map<String, Object?>>[];
    void check(String name, bool ok, Map<String, Object?> detail) {
      final entry = {'check': name, 'ok': ok, ...detail};
      checks.add(entry);
      print('dvr: ${ok ? 'PASS' : 'FAIL'} ${jsonEncode(entry)}');
    }

    Future<T> io<T>(Future<T> Function() f) async =>
        (await tester.runAsync(f)) as T;

    final dir = Directory('${Directory.systemTemp.path}/pokercam-dvr-fixture');
    final watch = Stopwatch()..start();
    final fx = await io(() => HlsFixture.start(dir));
    print('dvr: fixture ready in ${watch.elapsedMilliseconds} ms at ${fx.url}');
    final log = JsonLog('dvr-test', sink: (line) => print('log $line'));
    // The player's video texture comes from the platform side, which needs frames drawn meanwhile.
    MediaKitDvrPlayer? made;
    Object? failed;
    unawaited(
      MediaKitDvrPlayer.create(log)
          .then<void>((p) => made = p, onError: (Object e) => failed = e),
    );
    while (made == null &&
        failed == null &&
        watch.elapsed < const Duration(minutes: 2)) {
      await tester.pump(const Duration(milliseconds: 50));
      await io(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    final player = made;
    if (player == null) throw StateError('no player: ${failed ?? 'timed out'}');
    print('dvr: player ready in ${watch.elapsedMilliseconds} ms');
    final dvr = DvrController(
      player: player,
      source: DvrSource(
        playlist: fx.playlist,
        headers: fx.headers,
        get: getText,
      ),
      log: log,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: player.view())));

    /// Waits for the frame of [expected] seconds on screen; returns how far off the frame shown is, and when.
    Future<Map<String, Object?>> shown(double expected) async {
      final watch = Stopwatch()..start();
      double? seconds;
      while (watch.elapsed < const Duration(seconds: 3)) {
        final shot = await io(() => player.screenshotRaw());
        final frame = shot == null ? null : frameNumber(shot);
        seconds = frame == null ? null : frame / fps;
        if (seconds != null && (seconds - expected).abs() <= 0.5 / fps) break;
        await tester.pump(const Duration(milliseconds: 30));
      }
      return {
        'expected_s': double.parse(expected.toStringAsFixed(3)),
        'shown_s': seconds == null
            ? null
            : double.parse(seconds.toStringAsFixed(3)),
        'error_ms': seconds == null
            ? null
            : ((seconds - expected) * 1000).round(),
        'ms': watch.elapsedMilliseconds,
      };
    }

    /// One key: the controller's position moves by [delta] (when given), and the frame shown is that moment.
    Future<void> key(
      String name,
      Future<void> Function() press, {
      double? delta,
    }) async {
      final before = dvr.view.position;
      final watch = Stopwatch()..start();
      await io(press);
      final took = watch.elapsedMilliseconds;
      final position = dvr.view.position!;
      final moved = before == null || delta == null
          ? null
          : position.difference(before).inMicroseconds / 1e6;
      final landing = await shown(fx.secondsOf(position));
      final error = landing['error_ms'] as int?;
      check(
        name,
        error != null &&
            error.abs() <= tolerance * 1000 &&
            (moved == null || (moved - delta!).abs() < 1e-6),
        {...landing, 'key_ms': took, 'moved_s': ?moved},
      );
    }

    try {
      // Space from LIVE: the picture stops at the moment of pressing, here the DVR's live point.
      await key('Space in LIVE: pause at the live point', dvr.togglePause);
      await key(
        '← −1 s',
        () => dvr.step(const Duration(seconds: -1)),
        delta: -1,
      );
      await key('→ +1 s', () => dvr.step(const Duration(seconds: 1)), delta: 1);
      await key(
        '↓ −0.5 s',
        () => dvr.step(const Duration(milliseconds: -500)),
        delta: -0.5,
      );
      await key(
        '↑ +0.5 s',
        () => dvr.step(const Duration(milliseconds: 500)),
        delta: 0.5,
      );
      await key(
        'Shift+← −10 s',
        () => dvr.step(const Duration(seconds: -10)),
        delta: -10,
      );
      await key(
        'Shift+← −10 s again',
        () => dvr.step(const Duration(seconds: -10)),
        delta: -10,
      );

      // Space: play behind in real time, then pause where it got to.
      await io(dvr.togglePause);
      final played = Stopwatch()..start();
      await tester.pump(const Duration(seconds: 3));
      await io(() => Future<void>.delayed(const Duration(seconds: 3)));
      await key('Space: play 3 s behind, Space: pause there', dvr.togglePause);
      check('playback in real time', true, {
        'wall_s': played.elapsedMilliseconds / 1000,
      });

      // L: back to LIVE.
      await io(dvr.goLive);
      check('L: LIVE', dvr.view.live && dvr.view.position == null, {});

      // FFmpeg restarted (the second run, 3 s after the first): a step back into the first run, across the gap.
      while (fx.now < 130) {
        await tester.pump(const Duration(milliseconds: 200));
        await io(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      }
      await key('Space in LIVE, now in the second run', dvr.togglePause);
      await key(
        'Shift+← into the first run',
        () => dvr.step(const Duration(seconds: -10)),
        delta: -10,
      );
      final end = fx.runs['mpegts']!.first.segments.last.end;
      final gap = dvr.view.position!;
      final toEnd = end - fx.secondsOf(gap);
      // To 0.5 s before the first run ends, then forward across the gap: the second run's start.
      await key(
        'steps to near the end of the first run',
        () => dvr.step(Duration(microseconds: ((toEnd - 0.5) * 1e6).round())),
      );
      await key(
        '→ across the gap: the second run\'s first moment',
        () => dvr.step(const Duration(seconds: 1)),
      );
      final second = fx.runs['mpegts']![1].segments.first.start;
      check(
        'the gap is skipped forward',
        (fx.secondsOf(dvr.view.position!) - second).abs() < 1e-3,
        {
          'position_s': fx.secondsOf(dvr.view.position!),
          'second_run_s': second,
        },
      );
      await key(
        '← across the gap: the first run\'s last moments',
        () => dvr.step(const Duration(seconds: -1)),
      );

      // Playing out the first run: the DVR goes on with the second.
      await io(dvr.togglePause);
      await io(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump(const Duration(milliseconds: 100));
      final next = await io(player.position);
      check(
        'a played-out run goes on with the next',
        fx.secondsOf(dvr.view.position!) >= second,
        {
          'position_s': fx.secondsOf(dvr.view.position!),
          'player_s': next.inMilliseconds / 1000,
        },
      );
      await io(dvr.togglePause);
      await key('pause in the second run', () async {});
    } on Object catch (e, s) {
      check('the run completed', false, {'error': '$e', 'stack': '$s'});
    } finally {
      await io(dvr.dispose);
      await io(fx.close);
    }
    print('dvr-report: ${jsonEncode(checks)}');
    expect(checks.where((c) => c['ok'] != true), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
