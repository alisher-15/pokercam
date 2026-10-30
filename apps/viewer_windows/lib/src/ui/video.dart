import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The table's camera live (SPEC 8.2: RTCVideoView), letterboxed in black.
class LiveVideo extends StatefulWidget {
  const LiveVideo({super.key, required this.stream});

  final MediaStream stream;

  @override
  State<LiveVideo> createState() => _LiveVideoState();
}

class _LiveVideoState extends State<LiveVideo> {
  final _renderer = RTCVideoRenderer();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      if (!mounted) return;
      _renderer.srcObject = widget.stream;
      setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(LiveVideo old) {
    super.didUpdateWidget(old);
    // A reconnection or a new camera brings a new stream.
    if (_ready && !identical(old.stream, widget.stream)) {
      _renderer.srcObject = widget.stream;
    }
  }

  @override
  void dispose() {
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: _ready
        ? RTCVideoView(
            _renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          )
        : null,
  );
}
