/// What the DVR needs from a video player (SPEC 8.2): the media_kit one on Windows (media_kit_player.dart), a
/// fake in tests. Positions are from the start of the playlist it has open (its first segment's first frame).
library;

import 'package:flutter/widgets.dart';

abstract class DvrPlayer {
  /// Opens [url] (one run's EVENT playlist) paused on [start]; completes once that frame is shown.
  Future<void> open(Uri url, Map<String, String> headers, Duration start);

  /// Moves to [position] keeping pause or play; completes once that frame is shown.
  Future<void> seek(Duration position);

  Future<void> play();

  Future<void> pause();

  /// The position of the frame shown.
  Future<Duration> position();

  /// True once playback has reached the end of an ended run (EXT-X-ENDLIST), false after an open or a seek.
  Stream<bool> get ended;

  /// Stops reading (back in LIVE) but keeps the player for the next rewind.
  Future<void> stop();

  Future<void> dispose();

  /// The video, for the watch screen.
  Widget view();
}
