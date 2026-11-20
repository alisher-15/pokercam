/// The DVR on the watch screen (SPEC 8.2, 8.3): the keys, the red LIVE or yellow "−02:35" indicator and the
/// 10-minute scale with the recorded part.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import '../dvr/controller.dart';
import '../dvr/timeline.dart';

/// SPEC 8.3 for a key, or null when it is not a DVR key.
Future<void> Function(DvrController dvr)? dvrAction(
  KeyEvent event, {
  required bool shift,
}) {
  final repeat = event is KeyRepeatEvent;
  if (event is! KeyDownEvent && !repeat) return null;
  Future<void> Function(DvrController) step(Duration d) =>
      (dvr) => dvr.step(d);
  return switch (event.logicalKey) {
    LogicalKeyboardKey.arrowRight => step(const Duration(seconds: 1)),
    LogicalKeyboardKey.arrowLeft => step(
      shift ? const Duration(seconds: -10) : const Duration(seconds: -1),
    ),
    LogicalKeyboardKey.arrowUp => step(const Duration(milliseconds: 500)),
    LogicalKeyboardKey.arrowDown => step(const Duration(milliseconds: -500)),
    LogicalKeyboardKey.space when !repeat => (dvr) => dvr.togglePause(),
    LogicalKeyboardKey.keyL when !repeat => (dvr) => dvr.goLive(),
    _ => null,
  };
}

/// Whether the keyboard focus is in a text field, where the keys are the field's (SPEC 8.3).
bool focusInTextField() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Red LIVE, or yellow "−02:35" behind the real moment (with the pause sign), ticking while behind.
class DvrIndicator extends StatefulWidget {
  const DvrIndicator({super.key, required this.view, this.clock});

  final DvrView view;
  final DateTime Function()? clock;

  @override
  State<DvrIndicator> createState() => _DvrIndicatorState();
}

class _DvrIndicatorState extends State<DvrIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && !widget.view.live) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final view = widget.view;
    final position = view.position;
    final live = view.live || position == null;
    final now = (widget.clock ?? DateTime.now)();
    final text = live
        ? l10n.liveBadge
        : '${behindLabel(behind(position, now))}${view.paused ? '  ${l10n.dvrPaused}' : ''}';
    return Container(
      key: Key(live ? 'watch-live' : 'watch-behind'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: live ? Colors.red : Colors.amber,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: live ? Colors.white : Colors.black,
          fontWeight: FontWeight.bold,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The 10-minute scale under the video: what is recorded, and where the picture is (SPEC 8.2).
class DvrScaleBar extends StatelessWidget {
  const DvrScaleBar({super.key, required this.view, required this.now});

  final DvrView view;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final timeline = view.timeline;
    final position = view.live ? now : view.position ?? now;
    final scale = timeline == null || timeline.isEmpty
        ? const DvrScale(from: 1, to: 1, position: 1)
        : timeline.scale(position, now);
    final color = view.live ? Colors.red : Colors.amber;
    return SizedBox(
      key: const Key('dvr-scale'),
      height: 10,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          return Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: Colors.white12)),
              Positioned(
                left: scale.from * w,
                width: (scale.to - scale.from) * w,
                top: 0,
                bottom: 0,
                child: const ColoredBox(
                  key: Key('dvr-recorded'),
                  color: Colors.white38,
                ),
              ),
              Positioned(
                left: (scale.position * w - 2).clamp(0, w - 4),
                width: 4,
                top: -2,
                bottom: -2,
                child: ColoredBox(color: color),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The bottom strip while the DVR is there: the scale, its ends, the keys and the way back to LIVE.
class DvrBar extends StatefulWidget {
  const DvrBar({super.key, required this.view, required this.onLive});

  final DvrView view;
  final VoidCallback onLive;

  @override
  State<DvrBar> createState() => _DvrBarState();
}

class _DvrBarState extends State<DvrBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    const small = TextStyle(color: Colors.white70, fontSize: 12);
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DvrScaleBar(view: widget.view, now: DateTime.now()),
          const SizedBox(height: 4),
          Row(
            children: [
              const Text('−10:00', style: small),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  l10n.dvrKeys,
                  style: small,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              if (widget.view.live)
                Text(l10n.liveBadge, style: small)
              else
                TextButton(
                  key: const Key('dvr-live'),
                  onPressed: widget.onLive,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(l10n.dvrBackToLive),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
