import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';
import 'package:viewer_windows/src/dvr/controller.dart';

import 'fakes.dart';

/// media-server's playlist: run 3 has ten 1 s segments from t0 (sequences 100–109); after a 2 s gap run 4
/// has five (110–114).
final t0 = DateTime.utc(2026, 11, 20, 20);
String stamp(int seconds) =>
    t0.add(Duration(seconds: seconds)).toIso8601String();

String playlist({int runs = 2}) => [
  '#EXTM3U',
  '#EXT-X-VERSION:3',
  '#EXT-X-TARGETDURATION:2',
  '#EXT-X-MEDIA-SEQUENCE:100',
  '#EXT-X-DISCONTINUITY-SEQUENCE:3',
  for (var i = 0; i < 10; i++) ...[
    '#EXT-X-PROGRAM-DATE-TIME:${stamp(i)}',
    '#EXTINF:1.000,',
    'r7/$i.ts',
  ],
  if (runs > 1) ...[
    '#EXT-X-DISCONTINUITY',
    for (var i = 0; i < 5; i++) ...[
      '#EXT-X-PROGRAM-DATE-TIME:${stamp(12 + i)}',
      '#EXTINF:1.000,',
      'r8/$i.ts',
    ],
  ],
].join('\n');

DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  late FakePlayer player;
  late DvrController dvr;
  late DateTime now;
  late String text;

  setUp(() {
    player = FakePlayer();
    now = at(18000);
    text = playlist();
    dvr = DvrController(
      player: player,
      source: DvrSource(
        playlist: Uri.parse('http://media:3000/dvr/t/index.m3u8'),
        headers: const {'Authorization': 'Bearer v'},
        get: (url, headers) async => text,
      ),
      log: JsonLog('test', sink: (_) {}),
      clock: () => now,
      refreshEvery: const Duration(hours: 1),
      tickEvery: const Duration(hours: 1),
    );
  });

  tearDown(() => dvr.dispose());

  test('Space in LIVE stops at the moment of pressing, or at the DVR\'s live point if that is newer', () async {
    now = at(13500);
    await dvr.togglePause();
    expect(player.calls, ['open from=110 1500']);
    expect(dvr.view.live, isFalse);
    expect(dvr.view.paused, isTrue);
    expect(dvr.view.showing, isTrue);
    expect(dvr.view.position, at(13500));

    await dvr.goLive();
    now = at(30000);
    player.calls.clear();
    await dvr.togglePause();
    // The newest segment ends at 17 s: its last moments, not the wait for the next one.
    expect(player.calls, ['open from=110 4900']);
    expect(dvr.view.position, at(16900));
  });

  test(
    'every key of SPEC 8.3 moves the position exactly, within the open run',
    () async {
      now = at(16000);
      await dvr.togglePause();
      player.calls.clear();
      final steps = {
        const Duration(seconds: -1): 15000,
        const Duration(seconds: 1): 16000,
        const Duration(milliseconds: -500): 15500,
        const Duration(milliseconds: 500): 16000,
        const Duration(seconds: -2): 14000,
      };
      for (final MapEntry(key: delta, value: ms) in steps.entries) {
        await dvr.step(delta);
        expect(dvr.view.position, at(ms), reason: '$delta');
      }
      expect(player.calls, [
        'seek 3000',
        'seek 4000',
        'seek 3500',
        'seek 4000',
        'seek 2000',
      ]);
      expect(dvr.view.paused, isTrue);
    },
  );

  test(
    'a step back from LIVE plays on behind; forward from LIVE does nothing',
    () async {
      await dvr.step(const Duration(seconds: 1));
      expect(player.calls, isEmpty);
      expect(dvr.view.live, isTrue);
      now = at(15000);
      await dvr.step(const Duration(seconds: -10));
      // 5 s is in the first run: opened from its first segment.
      expect(player.calls, ['open from=100 5000', 'play']);
      expect(dvr.view.paused, isFalse);
      expect(dvr.view.position, at(5000));
    },
  );

  test('a step into the other run opens that run; across the gap it goes on in its direction', () async {
    now = at(13000);
    await dvr.togglePause();
    player.calls.clear();
    await dvr.step(const Duration(seconds: -2));
    // 11 s is in the gap between the runs: going back, the end of the first run.
    expect(player.calls, ['open from=100 9900']);
    expect(dvr.view.position, at(9900));
    await dvr.step(const Duration(seconds: 1));
    expect(player.calls.last, 'open from=110 0');
    expect(dvr.view.position, at(12000));
  });

  test('steps stop at the buffer\'s start and at the live point', () async {
    now = at(16000);
    await dvr.togglePause();
    await dvr.step(const Duration(seconds: -10));
    await dvr.step(const Duration(seconds: -10));
    expect(dvr.view.position, t0);
    await dvr.goLive();
    now = at(16500);
    await dvr.togglePause();
    await dvr.step(const Duration(seconds: 1));
    expect(dvr.view.position, at(16900));
  });

  test(
    'pause and play behind; L goes back to LIVE and stops the player',
    () async {
      now = at(16000);
      await dvr.step(const Duration(seconds: -1));
      expect(player.playing, isTrue);
      player.at = const Duration(milliseconds: 3700);
      await dvr.togglePause();
      expect(player.playing, isFalse);
      expect(dvr.view.position, at(15700));
      await dvr.togglePause();
      expect(player.playing, isTrue);
      await dvr.goLive();
      expect(player.calls.last, 'stop');
      expect(dvr.view.live, isTrue);
      expect(dvr.view.position, isNull);
    },
  );

  test('a played-out run goes on with the next run', () async {
    now = at(16000);
    await dvr.step(const Duration(seconds: -8));
    expect(player.calls, ['open from=100 8000', 'play']);
    player.endedController.add(true);
    await pumpEventQueue();
    await dvr.step(Duration.zero);
    expect(player.calls, contains('open from=110 0'));
    expect(player.playing, isTrue);
  });

  test('after the session limit the next step opens the run anew', () async {
    now = at(16000);
    await dvr.togglePause();
    now = now.add(const Duration(minutes: 11));
    await dvr.step(const Duration(seconds: -1));
    expect(player.calls.last, 'open from=110 3000');
  });
}
