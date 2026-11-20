// A DVR recording made up for the player tests (SPEC 12, stage 7): FFmpeg encodes two runs of H.264 in 1 s
// segments, as media-server's recorder writes them, and every frame carries its own number in 16 black and white
// stripes, so a screenshot tells exactly which moment the player shows. A small HTTP server then plays
// media-server: the recording grows in real time, with the playlists media-server serves. The runs are encoded
// twice, in fMP4 and in MPEG-TS segments, on the same timeline.
library;

import 'dart:io';

const width = 1280;
const height = 720;
const fps = 30;
const token = 'fixture-token';

/// Segment formats: FFmpeg's `-hls_segment_type`.
const segmentTypes = ['fmp4', 'mpegts'];

/// One FFmpeg run: its segments start at [start] seconds of real time; frame numbers count real time, so frame f
/// is the moment f / 30 s whatever the run.
class FixtureRun {
  FixtureRun(this.id, this.start, this.seconds);

  final int id;
  final double start;
  final int seconds;
  final segments = <FixtureSegment>[];
}

class FixtureSegment {
  FixtureSegment(this.run, this.sequence, this.uri, this.start, this.duration);

  final FixtureRun run;
  final int sequence;
  final String uri;

  /// Seconds of real time from the recording's start.
  final double start;
  final double duration;

  double get end => start + duration;
}

/// Encodes the runs into [dir]/[type] (skipped when they are there already) with the `ffmpeg` on PATH.
Future<List<FixtureRun>> encodeRuns(
  Directory dir,
  String type, {
  List<(double, int)> runs = const [(0, 120), (123, 30)],
}) async {
  final fmp4 = type == 'fmp4';
  final result = <FixtureRun>[];
  for (final (i, (start, seconds)) in runs.indexed) {
    final run = FixtureRun(i + 1, start, seconds);
    final out = Directory('${dir.path}/$type/r${run.id}');
    final playlist = File('${out.path}/index.m3u8');
    if (!playlist.existsSync()) {
      out.createSync(recursive: true);
      final first = (start * fps).round();
      final ffmpeg = await Process.run('ffmpeg', [
        ...['-hide_banner', '-loglevel', 'error', '-y'],
        ...['-f', 'lavfi', '-i', 'color=c=black:s=16x9:r=$fps:d=$seconds'],
        '-vf',
        "format=gray,geq=lum='if(bitand(N+$first,pow(2,X)),235,16)',"
            'scale=$width:$height:flags=neighbor,noise=alls=12:allf=t,format=yuv420p',
        ...['-c:v', 'libx264', '-preset', 'veryfast', '-bf', '0'],
        ...['-g', '$fps', '-keyint_min', '$fps', '-sc_threshold', '0'],
        ...['-b:v', '3M', '-maxrate', '4M', '-bufsize', '4M'],
        ...['-f', 'hls', '-hls_time', '1', '-hls_list_size', '0'],
        ...['-hls_segment_type', type],
        if (fmp4) ...['-hls_fmp4_init_filename', 'init.mp4'],
        ...['-hls_segment_filename', fmp4 ? '%d.m4s' : '%d.ts'],
        ...['-hls_flags', 'independent_segments', 'index.m3u8'],
      ], workingDirectory: out.path);
      if (ffmpeg.exitCode != 0) {
        throw StateError('ffmpeg failed: ${ffmpeg.stderr}');
      }
    }
    var at = start;
    var sequence = result.isEmpty ? 0 : result.last.segments.last.sequence + 1;
    double? duration;
    for (final line in playlist.readAsLinesSync().map((l) => l.trim())) {
      if (line.startsWith('#EXTINF:')) {
        duration = double.parse(line.substring(8).split(',').first);
      } else if (line.isNotEmpty && !line.startsWith('#') && duration != null) {
        run.segments.add(FixtureSegment(run, sequence++, line, at, duration));
        at += duration;
        duration = null;
      }
    }
    result.add(run);
  }
  return result;
}

/// Decodes the frame number from a raw BGRA screenshot of a fixture frame (media_kit `screenshot(format: null)`).
int? frameNumber(List<int> bgra) {
  if (bgra.length < width * height * 4) return null;
  final stride = bgra.length ~/ height;
  var n = 0;
  for (var bit = 0; bit < 16; bit++) {
    final x = bit * (width ~/ 16) + width ~/ 32;
    var sum = 0;
    for (final y in [height ~/ 4, height ~/ 2, height * 3 ~/ 4]) {
      final i = y * stride + x * 4;
      sum += bgra[i] + bgra[i + 1] + bgra[i + 2];
    }
    if (sum > 3 * 3 * 128) n |= 1 << bit;
  }
  return n;
}

/// media-server for the recording: by [preRecorded] seconds after [startedAt] the first run has that much
/// recorded, and segments appear as real time passes. Requests need `Authorization: Bearer fixture-token`, as
/// /dvr/ does. Paths: /{type}/live.m3u8, /{type}/event.m3u8?from=N, /{type}/r{run}/{file}.
class HlsFixture {
  HlsFixture._(this.dir, this.runs, this._server, this.preRecorded)
    : startedAt = DateTime.now() {
    _server.listen(_handle);
  }

  static Future<HlsFixture> start(
    Directory dir, {
    double preRecorded = 90,
    List<(double, int)> runs = const [(0, 120), (123, 30)],
  }) async {
    final encoded = {
      for (final type in segmentTypes)
        type: await encodeRuns(dir, type, runs: runs),
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return HlsFixture._(dir, encoded, server, preRecorded);
  }

  final Directory dir;
  final Map<String, List<FixtureRun>> runs;
  final HttpServer _server;
  final double preRecorded;
  final DateTime startedAt;

  /// Requests by kind ('playlist', 'segment', 'init'), for the report.
  final requests = <String, int>{};

  String get url => 'http://127.0.0.1:${_server.port}';

  Map<String, String> get headers => {'Authorization': 'Bearer $token'};

  /// Real time now, seconds from the recording's start.
  double get now =>
      preRecorded + DateTime.now().difference(startedAt).inMicroseconds / 1e6;

  /// The real moment of [seconds] from the recording's start.
  DateTime realTime(double seconds) => startedAt.add(
    Duration(microseconds: ((seconds - preRecorded) * 1e6).round()),
  );

  Iterable<FixtureSegment> finished(String type) =>
      runs[type]!.expand((r) => r.segments).where((s) => s.end <= now);

  FixtureSegment segment(String type, int sequence) => runs[type]!
      .expand((r) => r.segments)
      .firstWhere((s) => s.sequence == sequence);

  /// A run is over once a later run has a segment out.
  bool isOver(String type, FixtureRun run) =>
      finished(type).any((s) => s.run.id > run.id);

  Future<void> close() => _server.close(force: true);

  String _segment(String type, FixtureSegment s) => [
    '#EXT-X-PROGRAM-DATE-TIME:${realTime(s.start).toUtc().toIso8601String()}',
    '#EXTINF:${s.duration.toStringAsFixed(3)},',
    'r${s.run.id}/${s.uri}',
  ].join('\n');

  /// The sliding-window playlist media-server serves today (DvrIndex.render).
  String live(String type) {
    final segments = finished(type).toList();
    final lines = [
      '#EXTM3U',
      '#EXT-X-VERSION:${type == 'fmp4' ? 7 : 3}',
      '#EXT-X-TARGETDURATION:2',
      '#EXT-X-MEDIA-SEQUENCE:${segments.isEmpty ? 0 : segments.first.sequence}',
      '#EXT-X-DISCONTINUITY-SEQUENCE:0',
      '#EXT-X-INDEPENDENT-SEGMENTS',
    ];
    FixtureRun? run;
    for (final s in segments) {
      if (run != null && s.run != run) lines.add('#EXT-X-DISCONTINUITY');
      if (s.run != run && type == 'fmp4') {
        lines.add('#EXT-X-MAP:URI="r${s.run.id}/init.mp4"');
      }
      run = s.run;
      lines.add(_segment(type, s));
    }
    return '${lines.join('\n')}\n';
  }

  /// One run from segment [from] on, as an EVENT playlist: it only grows, and ends when the run is over.
  String event(String type, int from) {
    final first = segment(type, from);
    final segments = finished(type)
        .where((s) => s.run == first.run && s.sequence >= from)
        .toList();
    final all = first.run.segments.where((s) => s.sequence >= from).length;
    final lines = [
      '#EXTM3U',
      '#EXT-X-VERSION:${type == 'fmp4' ? 7 : 3}',
      '#EXT-X-TARGETDURATION:2',
      '#EXT-X-PLAYLIST-TYPE:EVENT',
      '#EXT-X-MEDIA-SEQUENCE:$from',
      '#EXT-X-INDEPENDENT-SEGMENTS',
      if (type == 'fmp4') '#EXT-X-MAP:URI="r${first.run.id}/init.mp4"',
      for (final s in segments) _segment(type, s),
      if (isOver(type, first.run) && segments.length == all) '#EXT-X-ENDLIST',
    ];
    return '${lines.join('\n')}\n';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.headers.value('authorization') != 'Bearer $token') {
        response.statusCode = 401;
        return;
      }
      final parts = request.uri.pathSegments;
      final type = parts.isEmpty ? '' : parts.first;
      if (!runs.containsKey(type)) {
        response.statusCode = 404;
        return;
      }
      final rest = parts.skip(1).join('/');
      if (rest == 'live.m3u8' || rest == 'event.m3u8') {
        requests.update('playlist', (n) => n + 1, ifAbsent: () => 1);
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        final from = int.tryParse(request.uri.queryParameters['from'] ?? '');
        response.write(
          rest == 'live.m3u8' ? live(type) : event(type, from ?? 0),
        );
        return;
      }
      final file = RegExp(r'^r(\d+)/(init\.mp4|\d+\.(m4s|ts))$')
          .firstMatch(rest);
      final f = file == null
          ? null
          : File('${dir.path}/$type/r${file[1]}/${file[2]}');
      if (f == null || !f.existsSync()) {
        response.statusCode = 404;
        return;
      }
      requests.update(
        file![2] == 'init.mp4' ? 'init' : 'segment',
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      response.headers.contentType = file[3] == 'ts'
          ? ContentType('video', 'mp2t')
          : ContentType('video', 'mp4');
      response.contentLength = f.lengthSync();
      await response.addStream(f.openRead());
    } finally {
      await response.close();
    }
  }
}
