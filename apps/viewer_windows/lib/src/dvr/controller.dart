/// The DVR of one table on the watch screen (SPEC 8.2, 8.3): LIVE or behind it, the position in real time,
/// steps, pause, back to LIVE. Times come from media-server's playlist ([DvrTimeline]); the player plays one
/// run at a time from that run's EVENT playlist (`?from=`), where real time = the playlist's first segment's
/// program date-time + the player's position.
library;

import 'dart:async';

import 'package:shared/shared.dart';

import 'player.dart';
import 'timeline.dart';

/// media-server's DVR for one table: /dvr/{table_id}/index.m3u8 with the table's viewer token.
class DvrSource {
  const DvrSource({
    required this.playlist,
    required this.headers,
    required this.get,
  });

  /// The sliding playlist (the buffer and its times).
  final Uri playlist;

  /// `Authorization: Bearer <viewer token>`.
  final Map<String, String> headers;

  /// GETs a playlist's text.
  final Future<String> Function(Uri url, Map<String, String> headers) get;

  /// The player's EVENT playlist of the run of segment [from].
  Uri run(int from) => playlist.replace(queryParameters: {'from': '$from'});
}

/// What the screen shows of the DVR.
class DvrView {
  const DvrView({
    this.live = true,
    this.position,
    this.paused = false,
    this.timeline,
    this.showing = false,
  });

  /// Red LIVE: the camera over WebRTC. Otherwise the DVR at [position].
  final bool live;

  /// The real moment shown (or being moved to), while not live.
  final DateTime? position;
  final bool paused;
  final DvrTimeline? timeline;

  /// The DVR player shows [position]; until then the screen keeps the last frame it had (no black screen).
  final bool showing;
}

class _Session {
  _Session(this.head, this.openedAt);

  /// The first segment of the playlist the player has open: the player's position 0.
  final DvrSegment head;
  final DateTime openedAt;
}

class DvrController {
  DvrController({
    required this.player,
    required this.source,
    required this.log,
    DateTime Function()? clock,
    this.refreshEvery = const Duration(seconds: 2),
    this.tickEvery = const Duration(milliseconds: 200),
    this.sessionLimit = const Duration(minutes: 10),
  }) : _clock = clock ?? DateTime.now {
    _ended = player.ended.listen((ended) {
      if (ended) unawaited(_serial(_nextRun));
    });
  }

  final DvrPlayer player;

  /// Replaced when the session gets a new token (each reconnection).
  DvrSource source;
  final Duration refreshEvery;
  final Duration tickEvery;

  /// The player reloads its playlist every second and the playlist only grows: after this long it is
  /// reopened at the next step, so it stays short.
  final Duration sessionLimit;
  final JsonLog log;
  final DateTime Function() _clock;

  final _views = StreamController<DvrView>.broadcast();
  DvrView _view = const DvrView();
  DvrTimeline? _timeline;
  _Session? _session;
  Timer? _refresher;
  Timer? _ticker;
  StreamSubscription<bool>? _ended;
  Future<void> _queue = Future.value();

  /// Where the keys put the position: steps pressed faster than the player lands add up from here.
  DateTime? _wanted;
  bool _disposed = false;

  DvrView get view => _view;
  Stream<DvrView> get views => _views.stream;

  void _emit(DvrView view) {
    _view = view;
    if (!_views.isClosed) _views.add(view);
  }

  /// → ← ↑ ↓ Shift+← (SPEC 8.3): from LIVE a step back starts playing behind; behind, the position moves and
  /// pause or play stays as it was.
  Future<void> step(Duration delta) => _serial(() async {
    if (_view.live && !delta.isNegative) return;
    final timeline = await _ensureTimeline();
    if (timeline == null) return;
    final from = _view.live
        ? _clock()
        : _view.paused
        ? (_wanted ?? _view.position!)
        : await _shown() ?? _view.position!;
    final target = timeline.step(from, delta);
    await _go(target, paused: _view.live ? false : _view.paused);
  });

  /// Space: from LIVE the picture stops at the moment of pressing; behind, pause or play.
  Future<void> togglePause() => _serial(() async {
    if (_view.live) {
      final timeline = await _ensureTimeline();
      if (timeline == null) return;
      await _go(timeline.clamp(_clock(), backward: true), paused: true);
      return;
    }
    final paused = !_view.paused;
    if (paused) {
      await player.pause();
      final shown = await _shown();
      _wanted = shown;
      _emit(_copy(paused: true, position: shown));
    } else {
      await player.play();
      _emit(_copy(paused: false));
    }
  });

  /// L: back to the camera over WebRTC.
  Future<void> goLive() => _serial(() async {
    if (_view.live) return;
    _stopTimers();
    _session = null;
    _wanted = null;
    _emit(DvrView(timeline: _timeline));
    await player.stop();
    log.info('dvr: live');
  });

  Future<void> dispose() async {
    _disposed = true;
    _stopTimers();
    await _ended?.cancel();
    await _queue.catchError((_) {});
    await player.dispose();
    await _views.close();
  }

  /// One action at a time, in the order of the keys.
  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => _disposed ? null : action());
    _queue = next.catchError((Object e) {
      log.warn('dvr: action failed', {'error': '$e'});
    });
    return _queue;
  }

  /// Moves the DVR to [target] (already inside the buffer): a seek in the open run, or the run opened anew.
  Future<void> _go(DateTime target, {required bool paused}) async {
    final timeline = _timeline!;
    final enter = _view.live;
    // At the end of a run (the live point, or the edge of a gap between runs) no segment holds the moment:
    // the segment that ends there, and its last moments rather than a wait for the next one.
    final segment =
        timeline.segmentAt(target) ??
        timeline.segments.lastWhere(
          (s) => s.start.isBefore(target),
          orElse: () => timeline.segments.first,
        );
    var at = target;
    if (!at.isBefore(segment.end)) {
      at = segment.end.subtract(const Duration(milliseconds: 100));
    }
    // The next step counts from the moment shown.
    _wanted = at;
    _emit(
      DvrView(
        live: false,
        position: at,
        paused: paused,
        timeline: timeline,
        showing: !enter && _view.showing,
      ),
    );
    if (enter) _startTimers();
    final session = _session;
    final watch = Stopwatch()..start();
    if (session != null &&
        session.head.run == segment.run &&
        !at.isBefore(session.head.start) &&
        _clock().difference(session.openedAt) < sessionLimit) {
      await player.seek(at.difference(session.head.start));
    } else {
      final head = timeline.firstOfRun(segment.run) ?? segment;
      await player.open(
        source.run(head.sequence),
        source.headers,
        at.difference(head.start),
      );
      _session = _Session(head, _clock());
    }
    if (!paused) await player.play();
    log.info('dvr: moved', {
      'to': at.toUtc().toIso8601String(),
      'ms': watch.elapsedMilliseconds,
      'reopened': !identical(session, _session),
      'paused': paused,
    });
    if (_wanted == at) _emit(_copy(position: at, showing: true));
  }

  /// The run being played has ended (FFmpeg restarted): on to the next run, if there is one.
  Future<void> _nextRun() async {
    final session = _session;
    final timeline = await _refresh();
    if (session == null || timeline == null || _view.live) return;
    final next = timeline.nextRun(session.head.run);
    if (next == null) return;
    await _go(next.start, paused: _view.paused);
  }

  /// The real moment of the frame the player shows.
  Future<DateTime?> _shown() async {
    final session = _session;
    if (session == null) return null;
    return session.head.start.add(await player.position());
  }

  Future<DvrTimeline?> _ensureTimeline() async =>
      _timeline != null && !_view.live ? _timeline : await _refresh();

  Future<DvrTimeline?> _refresh() async {
    try {
      final text = await source.get(source.playlist, source.headers);
      final timeline = DvrTimeline.parse(text);
      if (timeline.isEmpty) return _timeline;
      _timeline = timeline;
      if (!_disposed) _emit(_copy(timeline: timeline));
      return timeline;
    } on Object catch (e) {
      log.warn('dvr: playlist failed', {'error': '$e'});
      return _timeline;
    }
  }

  void _startTimers() {
    _refresher = Timer.periodic(refreshEvery, (_) => unawaited(_refresh()));
    _ticker = Timer.periodic(tickEvery, (_) => unawaited(_tick()));
  }

  void _stopTimers() {
    _refresher?.cancel();
    _ticker?.cancel();
  }

  /// While playing behind, the position follows the player.
  Future<void> _tick() async {
    if (_view.live || _view.paused || !_view.showing) return;
    final shown = await _shown();
    if (shown != null && !_view.live && !_view.paused) {
      _emit(_copy(position: shown));
    }
  }

  DvrView _copy({
    DateTime? position,
    bool? paused,
    DvrTimeline? timeline,
    bool? showing,
  }) => DvrView(
    live: _view.live,
    position: position ?? _view.position,
    paused: paused ?? _view.paused,
    timeline: timeline ?? _view.timeline,
    showing: showing ?? _view.showing,
  );
}
