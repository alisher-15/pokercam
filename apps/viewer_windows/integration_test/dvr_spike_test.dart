// Stage 7 spike (SPEC 8.2, 8.3): where media_kit's player (libmpv) really lands when it seeks in a DVR
// recording that is still growing. Every frame of the fixture carries its number, so each landing is
// checked against the screenshot of the frame shown, not the player's own idea of its position.
// The questions: can it seek in media-server's sliding playlist; in an EVENT playlist of one run; how
// precisely and how fast; does it stop at the end of a run; how long does opening at a moment take.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/hls_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DVR seeking with media_kit', (tester) async {
    MediaKit.ensureInitialized();
    final dir = Directory('${Directory.systemTemp.path}/pokercam-dvr-fixture');
    final watch = Stopwatch()..start();
    final fx = (await tester.runAsync(() => HlsFixture.start(dir)))!;
    print(
      'spike: fixture ready in ${watch.elapsedMilliseconds} ms at ${fx.url}',
    );
    final report = <Map<String, Object?>>[];
    void note(String step, Map<String, Object?> values) {
      final entry = {'step': step, ...values};
      report.add(entry);
      print('spike: ${jsonEncode(entry)}');
    }

    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    player.stream.log.listen(
      (l) => print('mpv ${l.level} ${l.prefix}: ${l.text.trim()}'),
    );
    player.stream.error.listen((e) => print('mpv error: $e'));
    final controller = VideoController(player);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Video(controller: controller, controls: NoVideoControls),
        ),
      ),
    );
    final native = player.platform! as NativePlayer;
    // media_kit's own demuxer options, plus: start a live or EVENT playlist at its first segment, not 3 from the end.
    await tester.runAsync(
      () => native.setProperty(
        'demuxer-lavf-o',
        'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
            'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto],live_start_index=0',
      ),
    );
    // The cache in memory: media_kit asks for one on disk, which fails here ("Failed to create file cache").
    await tester.runAsync(() => native.setProperty('cache-on-disk', 'no'));

    Future<T> io<T>(Future<T> Function() f) async =>
        (await tester.runAsync(f)) as T;

    Future<String> prop(String name) => io(() => native.getProperty(name));

    /// Polls the frame shown until it is [expected] seconds of real time, up to [timeout].
    Future<Map<String, Object?>> land(
      double expected, {
      Duration timeout = const Duration(seconds: 8),
    }) async {
      final watch = Stopwatch()..start();
      int? frame;
      var shots = 0;
      while (watch.elapsed < timeout) {
        final shot = await io(() => player.screenshot(format: null));
        shots++;
        frame = shot == null ? null : frameNumber(shot);
        if (frame != null && (frame - expected * fps).abs() < 0.5) break;
        await tester.pump(const Duration(milliseconds: 30));
      }
      final ms = watch.elapsedMilliseconds;
      final shown = frame == null ? null : frame / fps;
      return {
        'expected_s': expected,
        'shown_s': shown,
        'error_ms': shown == null ? null : ((shown - expected) * 1000).round(),
        'ms': ms,
        'shots': shots,
        'time_pos': await prop('time-pos'),
      };
    }

    Future<void> open(String path, {double? start}) => io(
      () => player.open(
        Media(
          '${fx.url}$path',
          httpHeaders: fx.headers,
          start: start == null
              ? null
              : Duration(microseconds: (start * 1e6).round()),
        ),
        play: false,
      ),
    );

    Future<void> seek(double seconds) =>
        io(() => player.seek(Duration(microseconds: (seconds * 1e6).round())));

    Future<void> wait(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 50));
        await io(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
    }

    /// The questions for one segment type; [full] adds playback, the run's end, the openings and the sliding
    /// playlist.
    Future<void> sequence(String type, {required bool full}) async {
      final p = '/$type';
      final short = full
          ? const Duration(seconds: 8)
          : const Duration(seconds: 3);
      // A. One run as an EVENT playlist from its first segment; the run's time 0 is the recording's 0.
      await open('$p/event.m3u8?from=0', start: 60.5);
      note(
        '$type A1 open EVENT from the run start at 60.5 s (paused)',
        await land(60.5, timeout: short),
      );
      var at = 60.5;
      for (final delta
          in full ? [1.0, -1.0, 0.5, -0.5, -10.0, -10.0, 1.0] : [1.0, -10.0]) {
        at += delta;
        await seek(at);
        note(
          '$type A2 step ${delta > 0 ? '+' : ''}$delta s → $at',
          await land(at, timeout: short),
        );
      }
      if (!full) return;
      await seek(5);
      note('$type A3 far back → 5 s', await land(5));
      final edge = fx.now - 3;
      await seek(edge);
      note(
        '$type A4 near the live edge → ${edge.toStringAsFixed(2)} s (now ${fx.now.toStringAsFixed(2)})',
        await land(edge),
      );
      note('$type A5 duration and cache', {
        'duration': await prop('duration'),
        'seekable': await prop('seekable'),
        'demuxer-cache-duration': await prop('demuxer-cache-duration'),
      });

      // B. Playing on in real time from a moment: the frame shown stays at time-pos (real = run start + time-pos).
      await seek(70);
      await land(70);
      final played = Stopwatch()..start();
      await io(() => player.play());
      await wait(const Duration(seconds: 4));
      await io(() => player.pause());
      final elapsed = played.elapsedMilliseconds / 1000;
      final timePos = double.tryParse(await prop('time-pos')) ?? -1;
      final paused = await land(timePos, timeout: const Duration(seconds: 2));
      note('$type B1 played ~4 s from 70 s', {
        'wall_s': elapsed,
        'time_pos': timePos,
        'shown_s': paused['shown_s'],
        'shown_minus_time_pos_ms': paused['error_ms'],
      });

      // C. The run ends (FFmpeg restarted): the EVENT playlist gets ENDLIST, the player stops on the last frame.
      while (fx.now < 125.5) {
        await wait(const Duration(milliseconds: 500));
      }
      await seek(117.5);
      note('$type C1 seek near the run end → 117.5 s', await land(117.5));
      final toEnd = Stopwatch()..start();
      await io(() => player.play());
      String eof = 'no';
      while (eof != 'yes' && toEnd.elapsed < const Duration(seconds: 12)) {
        await wait(const Duration(milliseconds: 100));
        eof = await prop('eof-reached');
      }
      final atEnd = toEnd.elapsedMilliseconds;
      final last = await land(
        119 + 29 / fps,
        timeout: const Duration(seconds: 2),
      );
      note('$type C2 played to the run end', {
        'eof_reached': eof,
        'ms_from_play': atEnd,
        'expected_ms': 2500,
        'last_frame_s': last['shown_s'],
        'idle': await prop('idle-active'),
      });

      // D. Opening at a moment: from the run's start with a seek, or from the moment's own segment.
      await open('$p/event.m3u8?from=0', start: 100.25);
      note('$type D1 open from the run start at 100.25 s', await land(100.25));
      await open('$p/event.m3u8?from=100', start: 0.25);
      note('$type D2 open from segment 100 at +0.25 s', await land(100.25));
      await open('$p/event.m3u8?from=120', start: 4);
      note(
        '$type D3 the second run: open from its start at +4 s',
        await land(127),
      );
      await seek(1.5);
      note('$type D4 the second run: seek to +1.5 s', await land(124.5));

      // E. media-server's sliding playlist as it is today: does the player seek in it at all?
      await open('$p/live.m3u8');
      note(
        '$type E1 open the sliding playlist (live_start_index=0)',
        await land(0, timeout: const Duration(seconds: 5)),
      );
      await seek(30);
      note(
        '$type E2 seek to 30 s in the sliding playlist',
        await land(30, timeout: const Duration(seconds: 5)),
      );
    }

    try {
      // MPEG-TS segments: the full set of questions.
      await sequence('mpegts', full: true);
      // fMP4 (media-server's segments today): the first seeks only, to confirm they break.
      await sequence('fmp4', full: false);
    } on Object catch (e, s) {
      note('the spike completed', {'error': '$e', 'stack': '$s'});
    } finally {
      note('requests', {...fx.requests});
      await io(() => player.dispose());
      await io(() => fx.close());
    }
    print('spike-report: ${jsonEncode(report)}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
