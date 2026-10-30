import 'dart:async';

import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
import 'package:shared/shared.dart';

/// What this PC receives right now (the watch screen's connection line).
class ReceiveStats {
  const ReceiveStats({
    required this.width,
    required this.height,
    required this.fps,
    required this.freezes,
    required this.packetsLost,
    this.codec,
  });

  final int width;
  final int height;
  final double fps;
  final int freezes;
  final int packetsLost;
  final String? codec;
}

/// The table camera's video on this PC (SPEC 8.2 live), behind an interface so the session's logic is
/// testable without WebRTC.
abstract interface class Subscriber {
  /// A new connection: learns the router's codecs (one mediasoup Device per connection).
  Future<void> prepare(ControlSocket socket);

  /// Consumes the camera's producer on a receive transport of this connection; returns what to render.
  Future<MediaStream> consume(ControlSocket socket);

  /// Fires when the transport fails (ICE or DTLS lost): the session reconnects.
  Stream<void> get failures;

  Future<ReceiveStats?> stats();

  /// Closes the consumer and the transport.
  Future<void> close();
}

/// mediasoup's Device API over flutter_webrtc (CLAUDE.md: never hand-built SDP).
class MediasoupSubscriber implements Subscriber {
  MediasoupSubscriber(this._log);

  final JsonLog _log;
  Device? _device;
  Transport? _transport;
  Consumer? _consumer;
  Completer<Consumer>? _consumed;
  final _failures = StreamController<void>.broadcast();

  @override
  Stream<void> get failures => _failures.stream;

  @override
  Future<void> prepare(ControlSocket socket) async {
    await close();
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
    _device = device;
  }

  @override
  Future<MediaStream> consume(ControlSocket socket) async {
    final device = _device ?? (throw StateError('prepare() first'));
    final transport = _transport ?? await _createTransport(socket, device);
    final reply = await socket.request('signaling.consume', {
      'transport_id': transport.id,
      'rtp_capabilities': withoutNulls(
        Map<String, dynamic>.from(device.rtpCapabilities.toMap()),
      ),
    });
    final consumed = Completer<Consumer>();
    _consumed = consumed;
    transport.consume(
      id: reply['consumer_id'] as String,
      producerId: reply['producer_id'] as String,
      peerId: 'camera',
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      rtpParameters: RtpParameters.fromMap(reply['rtp_parameters'] as Map),
    );
    // The library reports no error from consume (its queue drops it), so a failure here is only a timeout.
    final consumer = await consumed.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('consume did not complete'),
    );
    await _consumer?.close();
    _consumer = consumer;
    await socket.request('signaling.resume', {'consumer_id': consumer.id});
    _log.info('consuming', {
      'consumer_id': consumer.id,
      'producer_id': consumer.producerId,
    });
    return consumer.stream;
  }

  Future<Transport> _createTransport(
    ControlSocket socket,
    Device device,
  ) async {
    final t = await socket.request('signaling.create_transport', {
      'direction': 'recv',
    });
    final transport = device.createRecvTransportFromMap(
      {
        'id': t['transport_id'],
        'iceParameters': t['ice_parameters'],
        'iceCandidates': t['ice_candidates'],
        'dtlsParameters': t['dtls_parameters'],
      },
      consumerCallback: (Consumer consumer, [dynamic _]) {
        final waiting = _consumed;
        if (waiting != null && !waiting.isCompleted) waiting.complete(consumer);
      },
    );
    _transport = transport;
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
    transport.on('connectionstatechange', (Map data) {
      final state = data['connectionState'];
      _log.info('receive transport state', {'state': '$state'});
      if ((state == 'failed' || state == 'disconnected' || state == 'closed') &&
          identical(_transport, transport)) {
        _failures.add(null);
      }
    });
    await _untilReady(transport);
    return transport;
  }

  @override
  Future<ReceiveStats?> stats() async {
    final consumer = _consumer;
    if (consumer == null || consumer.closed) return null;
    final reports = (await consumer.getStats()) as List<StatsReport>;
    Map<dynamic, dynamic>? inbound;
    for (final r in reports) {
      if (r.type == 'inbound-rtp') inbound = r.values;
    }
    if (inbound == null) return null;
    String? codec;
    for (final r in reports) {
      if (r.type == 'codec' && r.id == inbound['codecId']) {
        codec = r.values['mimeType'] as String?;
      }
    }
    int number(String key) => (inbound![key] as num?)?.toInt() ?? 0;
    return ReceiveStats(
      width: number('frameWidth'),
      height: number('frameHeight'),
      fps: (inbound['framesPerSecond'] as num?)?.toDouble() ?? 0,
      freezes: number('freezeCount'),
      packetsLost: number('packetsLost'),
      codec: codec,
    );
  }

  @override
  Future<void> close() async {
    final consumer = _consumer;
    final transport = _transport;
    _consumer = null;
    _transport = null;
    _device = null;
    await consumer?.close();
    if (transport != null && !transport.closed) transport.close();
  }
}

/// The library starts a transport's peer connection without waiting for it (the handler's `run` is
/// `void async`): an operation before it exists fails on `_pc!` inside the library's queue, silently. The
/// transport's stats go through the same peer connection, so they answer once it is there (as in the camera app).
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
