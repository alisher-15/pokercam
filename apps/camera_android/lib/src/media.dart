import 'dart:async';

import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
import 'package:shared/shared.dart';

/// What the encoder sends right now (device.telemetry `stream`, the broadcast screen).
class PublishStats {
  const PublishStats({
    required this.bitrateKbps,
    required this.fps,
    required this.droppedFrames,
    this.codec,
    this.width,
    this.height,
    this.rttMs,
  });

  final int bitrateKbps;
  final double fps;
  final int droppedFrames;
  final String? codec;
  final int? width;
  final int? height;
  final int? rttMs;
}

/// The camera track and its publication to media-server (SPEC 6.3), behind an interface so the session's
/// logic is testable without WebRTC.
abstract interface class Publisher {
  /// Opens the back camera at 1080p30 once; returns the track id the camera2_control plugin works on.
  Future<String> openCamera();

  /// The camera's stream for the preview, once open.
  MediaStream? get stream;

  /// Produces the camera track on a new send transport of this socket's room (SPEC 5.3 signaling).
  Future<void> publish(ControlSocket socket, {required int maxBitrate});

  /// Fires when the transport fails (ICE or DTLS lost): the session reconnects.
  Stream<void> get failures;

  /// SPEC 6.4: 4, 3 or 2 Mbit/s by temperature.
  Future<void> setMaxBitrate(int bitsPerSecond);
  Future<PublishStats?> stats();

  /// Closes the transport and its producer; the camera stays open for the next publication.
  Future<void> unpublish();
  Future<void> closeCamera();
}

/// The one encoding the camera sends. The scalability mode must be set: the library reads it with `!`
/// (unified_plan.dart, send) and its produce queue swallows the null-check error, leaving produce hanging.
RtpEncodingParameters cameraEncoding(int maxBitrate) => RtpEncodingParameters(
  maxBitrate: maxBitrate,
  maxFramerate: 30,
  scalabilityMode: 'L1T1',
);

/// The library starts a transport's peer connection without waiting for it (the handler's `run` is
/// `void async`), and a produce before it exists fails on `_pc!` in that same swallowed way. The
/// transport's stats go through the same peer connection, so they answer once it is there.
Future<void> _untilReady(Transport transport) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    try {
      await transport.getState();
      return;
    } on Object {
      if (DateTime.now().isAfter(end)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

/// flutter_webrtc for the camera and mediasoup's Device API for the transport (CLAUDE.md: never hand-built SDP).
class MediasoupPublisher implements Publisher {
  MediasoupPublisher(
    this._log, {
    this.width = 1920,
    this.height = 1080,
    this.frameRate = 30,
  });

  final JsonLog _log;

  /// What the camera is opened at: SPEC 6.3 1080p30 (the CI emulator encodes in software and asks for less).
  final int width;
  final int height;
  final int frameRate;
  MediaStream? _stream;
  Transport? _transport;
  Producer? _producer;
  final _failures = StreamController<void>.broadcast();
  ({int bytes, DateTime at})? _lastSample;

  @override
  MediaStream? get stream => _stream;

  @override
  Stream<void> get failures => _failures.stream;

  @override
  Future<String> openCamera() async {
    final existing = _stream;
    if (existing != null) return existing.getVideoTracks().first.id!;
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'environment',
        'width': width,
        'height': height,
        'frameRate': frameRate,
      },
    });
    _stream = stream;
    return stream.getVideoTracks().first.id!;
  }

  @override
  Future<void> publish(ControlSocket socket, {required int maxBitrate}) async {
    final stream = _stream ?? (throw StateError('the camera is not open'));
    await unpublish();
    final device = Device();
    final caps = await socket.request(
      'signaling.get_router_rtp_capabilities',
      {},
    );
    await device.load(
      routerRtpCapabilities: RtpCapabilities.fromMap(
        caps['rtp_capabilities'] as Map,
      ),
    );
    if (!device.canProduce(RTCRtpMediaType.RTCRtpMediaTypeVideo)) {
      throw StateError('this phone cannot send video');
    }

    final t = await socket.request('signaling.create_transport', {
      'direction': 'send',
    });
    final produced = Completer<Producer>();
    final transport = device.createSendTransportFromMap(
      {
        'id': t['transport_id'],
        'iceParameters': t['ice_parameters'],
        'iceCandidates': t['ice_candidates'],
        'dtlsParameters': t['dtls_parameters'],
      },
      producerCallback: (Producer producer) {
        if (!produced.isCompleted) produced.complete(producer);
      },
    );
    _transport = transport;
    _log.info('send transport created', {'transport_id': transport.id});
    transport.on('connect', (Map data) {
      socket
          .request('signaling.connect_transport', {
            'transport_id': transport.id,
            'dtls_parameters': (data['dtlsParameters'] as DtlsParameters)
                .toMap(),
          })
          .then(
            (_) => data['callback'](),
            onError: (Object e) {
              _log.warn('connect_transport refused', {'error': '$e'});
              data['errback'](e);
            },
          );
    });
    transport.on('produce', (Map data) {
      socket
          .request('signaling.produce', {
            'transport_id': transport.id,
            'kind': 'video',
            'rtp_parameters': withoutNulls(
              (data['rtpParameters'] as RtpParameters).toMap(),
            ),
          })
          .then(
            (reply) => data['callback'](reply['producer_id']),
            onError: (Object e) {
              _log.warn('produce refused', {'error': '$e'});
              data['errback'](e);
            },
          );
    });
    transport.on('connectionstatechange', (Map data) {
      final state = data['connectionState'];
      _log.info('send transport state', {'state': '$state'});
      if ((state == 'failed' || state == 'disconnected' || state == 'closed') &&
          identical(_transport, transport)) {
        _log.warn('send transport $state');
        _failures.add(null);
      }
    });

    // H.264 first (SPEC 6.3: hardware encoder; the DVR records H.264 only), otherwise what the router offers.
    RtpCodecCapability? h264;
    for (final codec in device.rtpCapabilities.codecs) {
      if (codec.mimeType.toLowerCase() == 'video/h264') {
        h264 = codec;
        break;
      }
    }
    await _untilReady(transport);
    transport.produce(
      track: stream.getVideoTracks().first,
      stream: stream,
      source: 'camera',
      codec: h264,
      stopTracks: false,
      encodings: [cameraEncoding(maxBitrate)],
    );
    // The library reports no error from produce (its queue drops it), so a failure here is only a timeout.
    final producer = await produced.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException(
        'produce did not complete (codec ${h264?.mimeType ?? 'router default'})',
      ),
    );
    _producer = producer;
    // SPEC 6.3: under pressure drop frames, never resolution (the cards must stay readable).
    final sender = producer.rtpSender;
    if (sender != null) {
      try {
        final parameters = sender.parameters;
        parameters.degradationPreference =
            RTCDegradationPreference.MAINTAIN_RESOLUTION;
        await sender.setParameters(parameters);
      } on Object catch (e) {
        _log.warn('degradationPreference not accepted', {'error': '$e'});
      }
    }
    _lastSample = null;
    _log.info('producing', {
      'producer_id': producer.id,
      'codec': h264?.mimeType ?? 'router default',
    });
  }

  @override
  Future<void> setMaxBitrate(int bitsPerSecond) async {
    final producer = _producer;
    if (producer == null || producer.closed) return;
    await producer.setRtpEncodingParameters(
      RtpEncodingParameters(maxBitrate: bitsPerSecond, active: true),
    );
    _log.info('max bitrate set', {'bitrate': bitsPerSecond});
  }

  @override
  Future<PublishStats?> stats() async {
    final producer = _producer;
    if (producer == null || producer.closed) return null;
    final reports = (await producer.getStats()) as List<StatsReport>;
    Map<dynamic, dynamic>? find(String type) {
      for (final r in reports) {
        if (r.type == type) return r.values;
      }
      return null;
    }

    final out = find('outbound-rtp');
    if (out == null) return null;
    final now = DateTime.now();
    final bytes = (out['bytesSent'] as num?)?.toInt() ?? 0;
    final last = _lastSample;
    _lastSample = (bytes: bytes, at: now);
    final kbps = last == null || !now.isAfter(last.at)
        ? 0
        : ((bytes - last.bytes) * 8 / now.difference(last.at).inMilliseconds)
              .round();
    String? codec;
    for (final r in reports) {
      if (r.type == 'codec' && r.id == out['codecId']) {
        codec = r.values['mimeType'] as String?;
      }
    }
    final source = find('media-source');
    final framesIn = (source?['frames'] as num?)?.toInt();
    final encoded = (out['framesEncoded'] as num?)?.toInt() ?? 0;
    final pair = find('candidate-pair');
    final rtt = (pair?['currentRoundTripTime'] as num?)?.toDouble();
    return PublishStats(
      bitrateKbps: kbps < 0 ? 0 : kbps,
      fps: (out['framesPerSecond'] as num?)?.toDouble() ?? 0,
      droppedFrames: framesIn == null || framesIn < encoded
          ? 0
          : framesIn - encoded,
      codec: codec,
      width: (out['frameWidth'] as num?)?.toInt(),
      height: (out['frameHeight'] as num?)?.toInt(),
      rttMs: rtt == null ? null : (rtt * 1000).round(),
    );
  }

  @override
  Future<void> unpublish() async {
    final transport = _transport;
    _transport = null;
    _producer = null;
    if (transport != null && !transport.closed) transport.close();
  }

  @override
  Future<void> closeCamera() async {
    await unpublish();
    final stream = _stream;
    _stream = null;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }
}
