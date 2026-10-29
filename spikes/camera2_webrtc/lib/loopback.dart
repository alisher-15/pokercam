import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The camera at 1080p30 sent through a WebRTC connection to a second connection in the same app:
/// the video really is encoded and decoded, as it will be on its way to the media server.
class LoopbackSession {
  LoopbackSession._(this.local, this.remote, this._sender, this._receiver);

  final MediaStream local;
  final MediaStream remote;
  final RTCPeerConnection _sender;
  final RTCPeerConnection _receiver;

  MediaStreamTrack get videoTrack => local.getVideoTracks().first;

  static Future<LoopbackSession> start() async {
    final local = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'environment',
        'width': 1920,
        'height': 1080,
        'frameRate': 30,
      },
    });
    final config = {
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    };
    final sender = await createPeerConnection(config);
    final receiver = await createPeerConnection(config);
    final remote = Completer<MediaStream>();
    receiver.onTrack = (event) {
      if (event.streams.isNotEmpty && !remote.isCompleted) {
        remote.complete(event.streams.first);
      }
    };

    final transceiver = await sender.addTransceiver(
      track: local.getVideoTracks().first,
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendOnly,
        streams: [local],
        sendEncodings: [RTCRtpEncoding(maxBitrate: 4000000, maxFramerate: 30)],
      ),
    );
    // H.264 first (SPEC 6.3); whatever the phone has otherwise.
    final codecs = (await getRtpSenderCapabilities('video')).codecs ?? [];
    bool isH264(RTCRtpCodecCapability c) =>
        c.mimeType.toLowerCase() == 'video/h264';
    await transceiver.setCodecPreferences([
      ...codecs.where(isH264),
      ...codecs.where((c) => !isH264(c)),
    ]);
    try {
      final parameters = transceiver.sender.parameters;
      parameters.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;
      await transceiver.sender.setParameters(parameters);
    } catch (_) {
      // Not every libwebrtc build accepts it; the report shows the resolution actually sent.
    }

    // Whole descriptions with their candidates, so no candidate arrives before its description.
    await sender.setLocalDescription(await sender.createOffer());
    await _gathered(sender);
    await receiver.setRemoteDescription((await sender.getLocalDescription())!);
    await receiver.setLocalDescription(await receiver.createAnswer());
    await _gathered(receiver);
    await sender.setRemoteDescription((await receiver.getLocalDescription())!);

    return LoopbackSession._(
      local,
      await remote.future.timeout(const Duration(seconds: 15)),
      sender,
      receiver,
    );
  }

  static Future<void> _gathered(RTCPeerConnection pc) async {
    for (var i = 0; i < 50; i++) {
      if (pc.iceGatheringState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Encoder and decoder side of the stream right now.
  Future<Map<String, dynamic>> stats() async {
    final sent = await _sender.getStats();
    final received = await _receiver.getStats();
    Map<dynamic, dynamic>? find(List<StatsReport> reports, String type) {
      for (final r in reports) {
        if (r.type == type &&
            (r.values['kind'] ?? r.values['mediaType']) == 'video') {
          return r.values;
        }
      }
      return null;
    }

    final out = find(sent, 'outbound-rtp') ?? {};
    final inbound = find(received, 'inbound-rtp') ?? {};
    String? codec;
    for (final r in sent) {
      if (r.type == 'codec' && r.id == out['codecId']) {
        codec = r.values['mimeType'] as String?;
      }
    }
    return {
      'codec': codec,
      'encoder': out['encoderImplementation'],
      'sent_size': '${out['frameWidth']}x${out['frameHeight']}',
      'sent_fps': out['framesPerSecond'],
      'frames_encoded': out['framesEncoded'] ?? 0,
      'bytes_sent': out['bytesSent'] ?? 0,
      'quality_limitation': out['qualityLimitationReason'],
      'received_size': '${inbound['frameWidth']}x${inbound['frameHeight']}',
      'received_fps': inbound['framesPerSecond'],
      'frames_decoded': inbound['framesDecoded'] ?? 0,
    };
  }

  Future<void> dispose() async {
    await _sender.close();
    await _receiver.close();
    for (final track in local.getTracks()) {
      await track.stop();
    }
    await local.dispose();
  }
}
