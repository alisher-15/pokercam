/// The DVR player on Windows (SPEC 8.2): media_kit over libmpv. Seeks are exact (hr-seek): the stage 7 spike
/// measured every step of SPEC 8.3 landing on the expected frame, 60–600 ms per step, in MPEG-TS segments.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared/shared.dart';

import 'player.dart';

class MediaKitDvrPlayer implements DvrPlayer {
  MediaKitDvrPlayer._(this._player, this._controller, this._log);

  /// [MediaKit.ensureInitialized] must have run (main).
  static Future<MediaKitDvrPlayer> create(JsonLog log) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.error,
        title: 'PokerCam DVR',
      ),
    );
    final controller = VideoController(player);
    final native = player.platform! as NativePlayer;
    // media_kit's demuxer options, plus: open a growing (EVENT) playlist at its first segment, not 3 from its
    // end, so that the player's 0 is the playlist's first segment.
    await native.setProperty(
      'demuxer-lavf-o',
      'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
          'protocol_whitelist=[tcp,tls,http,https,crypto],live_start_index=0',
    );
    // media_kit asks for the cache on disk, which needs a cache directory; in memory it is.
    await native.setProperty('cache-on-disk', 'no');
    final dvr = MediaKitDvrPlayer._(player, controller, log);
    await native.observeProperty('eof-reached', (value) async {
      if (!dvr._ended.isClosed) dvr._ended.add(value == 'yes');
    });
    player.stream.error.listen((e) => log.warn('dvr player', {'error': e}));
    return dvr;
  }

  final Player _player;
  final VideoController _controller;
  final JsonLog _log;
  final _ended = StreamController<bool>.broadcast();

  NativePlayer get _native => _player.platform! as NativePlayer;

  /// How long a seek or an open may take before it counts as failed.
  static const settleTimeout = Duration(seconds: 8);

  @override
  Stream<bool> get ended => _ended.stream;

  @override
  Future<void> open(
    Uri url,
    Map<String, String> headers,
    Duration start,
  ) async {
    await _player.open(
      Media(url.toString(), httpHeaders: headers, start: start),
      play: false,
    );
    await _settle(start);
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    await _settle(position);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<Duration> position() async {
    final seconds = double.tryParse(await _native.getProperty('time-pos'));
    return seconds == null
        ? Duration.zero
        : Duration(microseconds: (seconds * 1e6).round());
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    await _player.dispose();
    await _ended.close();
  }

  /// The frame shown as raw BGRA (the tests read the frame numbers of their recording from it).
  Future<Uint8List?> screenshotRaw() => _player.screenshot(format: null);

  @override
  Widget view() => Video(
    controller: _controller,
    controls: NoVideoControls,
    fill: Colors.black,
  );

  /// Waits until mpv has finished seeking and shows the first frame at or after [target] (hr-seek). Its
  /// time-pos alone is not enough: mpv reports the target at once, before any frame is decoded.
  Future<void> _settle(Duration target) async {
    final want = target.inMicroseconds / 1e6;
    final watch = Stopwatch()..start();
    while (watch.elapsed < settleTimeout) {
      final seeking = await _native.getProperty('seeking');
      final at = double.tryParse(await _native.getProperty('time-pos'));
      if (seeking == 'no' &&
          at != null &&
          at >= want - 0.001 &&
          at < want + 0.1) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    _log.warn('dvr player: no frame at the target', {
      'target_s': want,
      'time_pos': await _native.getProperty('time-pos'),
    });
    throw TimeoutException(
      'the DVR player did not reach $target',
      settleTimeout,
    );
  }
}
