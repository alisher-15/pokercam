import 'package:flutter_test/flutter_test.dart';
import 'package:viewer_windows/src/dvr/timeline.dart';

/// media-server's playlist (DvrIndex.render): run 1 has five 1-second segments from t0; FFmpeg restarted, and
/// run 2 starts 2 s after run 1 ended, with three segments (one of them shorter).
final t0 = DateTime.utc(2026, 11, 19, 20, 0, 0);
String stamp(Duration d) => t0.add(d).toIso8601String();

final playlist = [
  '#EXTM3U',
  '#EXT-X-VERSION:7',
  '#EXT-X-TARGETDURATION:1',
  '#EXT-X-MEDIA-SEQUENCE:100',
  '#EXT-X-DISCONTINUITY-SEQUENCE:3',
  '#EXT-X-INDEPENDENT-SEGMENTS',
  '#EXT-X-MAP:URI="r4/init.mp4"',
  for (var i = 0; i < 5; i++) ...[
    '#EXT-X-PROGRAM-DATE-TIME:${stamp(Duration(seconds: i))}',
    '#EXTINF:1.000,',
    'r4/$i.m4s',
  ],
  '#EXT-X-DISCONTINUITY',
  '#EXT-X-MAP:URI="r5/init.mp4"',
  '#EXT-X-PROGRAM-DATE-TIME:${stamp(const Duration(seconds: 7))}',
  '#EXTINF:1.000,',
  'r5/0.m4s',
  '#EXT-X-PROGRAM-DATE-TIME:${stamp(const Duration(seconds: 8))}',
  '#EXTINF:0.967,',
  'r5/1.m4s',
  '#EXT-X-PROGRAM-DATE-TIME:${stamp(const Duration(milliseconds: 8967))}',
  '#EXTINF:1.000,',
  'r5/2.m4s',
].join('\n');

DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  final timeline = DvrTimeline.parse(playlist);

  test('reads media-server\'s playlist: sequences, real times, durations, the run boundary', () {
    expect(timeline.segments, hasLength(8));
    expect(timeline.segments.first.sequence, 100);
    expect(timeline.segments.last.sequence, 107);
    expect(timeline.segments[5].discontinuity, isTrue);
    expect(timeline.segments[5].uri, 'r5/0.m4s');
    expect(timeline.segments[6].duration, const Duration(milliseconds: 967));
    expect(timeline.start, t0);
    expect(timeline.liveEdge, at(9967));
  });

  test('a segment without its own date follows the one before; one with none before is left out', () {
    final parsed = DvrTimeline.parse(
      [
        '#EXTM3U',
        '#EXT-X-MEDIA-SEQUENCE:7',
        '#EXTINF:1.000,',
        'unknown.m4s',
        '#EXT-X-PROGRAM-DATE-TIME:${stamp(Duration.zero)}',
        '#EXTINF:1.000,',
        'a.m4s',
        '#EXTINF:0.500,',
        'b.m4s',
      ].join('\n'),
    );
    expect(parsed.segments.map((s) => s.uri), ['a.m4s', 'b.m4s']);
    expect(parsed.segments.map((s) => s.sequence), [8, 9]);
    expect(parsed.segments.last.start, at(1000));
    expect(parsed.liveEdge, at(1500));
    expect(DvrTimeline.parse('#EXTM3U\n').isEmpty, isTrue);
  });

  test('the segment holding a moment; none in the gap between runs or outside the buffer', () {
    expect(timeline.segmentAt(at(2500))?.uri, 'r4/2.m4s');
    expect(timeline.segmentAt(at(8966))?.uri, 'r5/1.m4s');
    expect(timeline.segmentAt(at(8967))?.uri, 'r5/2.m4s');
    expect(timeline.segmentAt(at(6000)), isNull);
    expect(timeline.segmentAt(at(-1)), isNull);
    expect(timeline.segmentAt(at(9967)), isNull);
  });

  test(
    'every step of SPEC 8.3 lands exactly where expected inside the buffer',
    () {
      final position = at(3000);
      final steps = {
        const Duration(seconds: 1): at(4000),
        const Duration(seconds: -1): at(2000),
        const Duration(milliseconds: 500): at(3500),
        const Duration(milliseconds: -500): at(2500),
        const Duration(seconds: -2): at(1000),
      };
      for (final MapEntry(key: delta, value: expected) in steps.entries) {
        expect(timeline.step(position, delta), expected, reason: '$delta');
      }
    },
  );

  test('steps stop at the live point going forward and at the buffer\'s start going back', () {
    expect(timeline.step(at(9500), const Duration(seconds: 1)), at(9967));
    expect(timeline.step(at(500), const Duration(seconds: -10)), t0);
    expect(timeline.clamp(at(60000)), timeline.liveEdge);
  });

  test('a step into the gap between runs goes on in its direction', () {
    expect(timeline.step(at(4500), const Duration(seconds: 1)), at(7000));
    expect(timeline.step(at(7200), const Duration(seconds: -1)), at(5000));
  });

  test('the indicator: behind the real moment in whole seconds, and the live point\'s own lag', () {
    final now = at(11500);
    expect(behind(at(9967), now), const Duration(milliseconds: 1533));
    expect(behindLabel(behind(at(9967), now)), '−00:02');
    expect(behindLabel(const Duration(minutes: 2, seconds: 35)), '−02:35');
    expect(behind(at(12000), now), Duration.zero);
    expect(timeline.liveLag(now), const Duration(milliseconds: 1533));
  });

  test('the 10-minute scale: the buffer and the position as fractions of the window ending now', () {
    final now = at(60 * 1000);
    final scale = timeline.scale(
      at(5000),
      now,
      window: const Duration(minutes: 1),
    );
    expect(scale.from, closeTo(0, 1e-9));
    expect(scale.to, closeTo(9.967 / 60, 1e-9));
    expect(scale.position, closeTo(5 / 60, 1e-9));
    final wide = timeline.scale(at(5000), now);
    expect(wide.from, closeTo(1 - 60 / 600, 1e-9));
  });
}
