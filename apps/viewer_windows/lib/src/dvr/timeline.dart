/// The DVR's time (SPEC 8.2, 8.3): where the buffer starts and ends in real time, where a step lands, how far
/// behind the real moment a position is. Pure Dart with no player and no UI, so it is tested on its own
/// (SPEC 12, stage 7); the player maps real time to its own position elsewhere.
library;

/// One segment of the DVR playlist (SPEC 7.2): when its first frame was captured and how long it lasts.
class DvrSegment {
  const DvrSegment({
    required this.sequence,
    required this.start,
    required this.duration,
    required this.uri,
    this.discontinuity = false,
    this.run = 0,
  });

  /// EXT-X-MEDIA-SEQUENCE numbering.
  final int sequence;

  /// EXT-X-PROGRAM-DATE-TIME: the real time of the segment's first frame.
  final DateTime start;
  final Duration duration;
  final String uri;

  /// The first segment of a new FFmpeg run (the camera came back, FFmpeg restarted): a gap may precede it.
  final bool discontinuity;

  /// Its run: the discontinuity sequence number (RFC 8216 6.2.2), the same for one segment in every reload.
  /// Segments of one run play as one stream; another run is another stream for the player.
  final int run;

  DateTime get end => start.add(duration);
}

/// The 10-minute scale under the video: the recorded part and the position, as fractions of the window.
class DvrScale {
  const DvrScale({
    required this.from,
    required this.to,
    required this.position,
  });

  final double from;
  final double to;
  final double position;
}

/// The segments of one DVR playlist, oldest first, and what can be done with them.
class DvrTimeline {
  DvrTimeline(List<DvrSegment> segments)
    : segments = List.unmodifiable(segments);

  /// media-server's playlist (SPEC 7.2: EXT-X-PROGRAM-DATE-TIME on every segment, EXT-X-DISCONTINUITY between
  /// FFmpeg runs). A segment without its own date follows the one before it; segments before the first date
  /// are left out, as their time is unknown.
  factory DvrTimeline.parse(String playlist) {
    final segments = <DvrSegment>[];
    var sequence = 0;
    var run = 0;
    Duration? duration;
    DateTime? date;
    var discontinuity = false;
    for (final raw in playlist.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.parse(line.substring(22));
      } else if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
        run = int.parse(line.substring(30));
      } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
        date = DateTime.parse(line.substring(25)).toUtc();
      } else if (line.startsWith('#EXTINF:')) {
        final seconds = double.parse(line.substring(8).split(',').first);
        duration = Duration(microseconds: (seconds * 1e6).round());
      } else if (line == '#EXT-X-DISCONTINUITY') {
        discontinuity = true;
        run++;
      } else if (!line.startsWith('#')) {
        final start =
            date ??
            (segments.isEmpty || discontinuity ? null : segments.last.end);
        if (duration != null && start != null) {
          segments.add(
            DvrSegment(
              sequence: sequence,
              start: start,
              duration: duration,
              uri: line,
              discontinuity: discontinuity,
              run: run,
            ),
          );
        }
        sequence++;
        duration = null;
        date = null;
        discontinuity = false;
      }
    }
    return DvrTimeline(segments);
  }

  final List<DvrSegment> segments;

  bool get isEmpty => segments.isEmpty;

  /// The oldest recorded moment.
  DateTime get start => segments.first.start;

  /// The DVR's live point: the end of the newest segment.
  DateTime get liveEdge => segments.last.end;

  /// The oldest segment of [run] in the buffer.
  DvrSegment? firstOfRun(int run) {
    for (final segment in segments) {
      if (segment.run == run) return segment;
    }
    return null;
  }

  /// The first segment of the run after [run], if FFmpeg has started one.
  DvrSegment? nextRun(int run) {
    for (final segment in segments) {
      if (segment.run > run) return segment;
    }
    return null;
  }

  /// The segment holding [time], or null outside the buffer or in a gap between runs.
  DvrSegment? segmentAt(DateTime time) {
    for (final segment in segments) {
      if (!time.isBefore(segment.start) && time.isBefore(segment.end)) {
        return segment;
      }
    }
    return null;
  }

  /// The nearest recorded moment to [time]: inside the buffer, and out of a gap between runs, going on in the
  /// direction of travel ([backward] to the end of the run before, else to the start of the run after).
  DateTime clamp(DateTime time, {bool backward = false}) {
    if (time.isBefore(start)) return start;
    if (!time.isBefore(liveEdge)) return liveEdge;
    if (segmentAt(time) != null) return time;
    for (var i = 1; i < segments.length; i++) {
      final before = segments[i - 1];
      final after = segments[i];
      if (!time.isBefore(before.end) && time.isBefore(after.start)) {
        return backward ? before.end : after.start;
      }
    }
    return time;
  }

  /// SPEC 8.3: [position] moved by [delta]; never past the DVR's live point, never before the buffer's start.
  DateTime step(DateTime position, Duration delta) =>
      clamp(position.add(delta), backward: delta.isNegative);

  /// How far the DVR's live point lags the real moment (SPEC 8.2: about 1.5 s, shown on the indicator).
  Duration liveLag(DateTime now) => _notNegative(now.difference(liveEdge));

  /// The 10-minute scale ending at [now].
  DvrScale scale(
    DateTime position,
    DateTime now, {
    Duration window = const Duration(minutes: 10),
  }) {
    final left = now.subtract(window);
    double at(DateTime t) =>
        (t.difference(left).inMicroseconds / window.inMicroseconds).clamp(
          0.0,
          1.0,
        );
    return DvrScale(from: at(start), to: at(liveEdge), position: at(position));
  }
}

/// How far behind the real moment [position] is (the yellow indicator), never negative.
Duration behind(DateTime position, DateTime now) =>
    _notNegative(now.difference(position));

/// The indicator's text: "−02:35" (SPEC 8.2), whole seconds.
String behindLabel(Duration behind) {
  final seconds = (behind.inMilliseconds / 1000).round();
  final minutes = seconds ~/ 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '−${two(minutes)}:${two(seconds % 60)}';
}

Duration _notNegative(Duration d) => d.isNegative ? Duration.zero : d;
