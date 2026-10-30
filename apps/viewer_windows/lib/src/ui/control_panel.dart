import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared/shared.dart';

import '../session.dart';
import 'watch_screen.dart';

/// The parameters in the order of SPEC 6.2, with what the camera can do.
List<(CameraParam, ParamCapability)> capabilityList(
  CameraParamCapabilities caps,
) => [
  (CameraParam.FOCUS, caps.focus),
  (CameraParam.ISO, caps.iso),
  (CameraParam.EXPOSURE, caps.exposure),
  (CameraParam.BRIGHTNESS, caps.brightness),
  (CameraParam.CONTRAST, caps.contrast),
  (CameraParam.WHITE_BALANCE, caps.whiteBalance),
  (CameraParam.ZOOM, caps.zoom),
];

String paramLabel(AppLocalizations l10n, CameraParam param) => switch (param) {
  CameraParam.FOCUS => l10n.paramFocus,
  CameraParam.ISO => l10n.paramIso,
  CameraParam.EXPOSURE => l10n.paramExposure,
  CameraParam.BRIGHTNESS => l10n.paramBrightness,
  CameraParam.CONTRAST => l10n.paramContrast,
  CameraParam.WHITE_BALANCE => l10n.paramWhiteBalance,
  CameraParam.ZOOM => l10n.paramZoom,
};

String modeLabel(AppLocalizations l10n, ControlMode mode) => switch (mode) {
  ControlMode.AUTO => l10n.modeAuto,
  ControlMode.MANUAL => l10n.modeManual,
  ControlMode.PRESET => l10n.modePreset,
};

String presetLabel(AppLocalizations l10n, WhiteBalancePreset preset) =>
    switch (preset) {
      WhiteBalancePreset.INCANDESCENT => l10n.presetIncandescent,
      WhiteBalancePreset.FLUORESCENT => l10n.presetFluorescent,
      WhiteBalancePreset.WARM_FLUORESCENT => l10n.presetWarmFluorescent,
      WhiteBalancePreset.DAYLIGHT => l10n.presetDaylight,
      WhiteBalancePreset.CLOUDY_DAYLIGHT => l10n.presetCloudyDaylight,
      WhiteBalancePreset.TWILIGHT => l10n.presetTwilight,
      WhiteBalancePreset.SHADE => l10n.presetShade,
    };

/// A manual value as the camera means it: exposure in nanoseconds is shown in milliseconds.
String valueLabel(CameraParam param, double value) => switch (param) {
  CameraParam.EXPOSURE => '${(value / 1e6).toStringAsFixed(1)} ms',
  CameraParam.ZOOM => '${value.toStringAsFixed(1)}×',
  CameraParam.WHITE_BALANCE => '${value.round()} K',
  CameraParam.ISO => '${value.round()}',
  _ => value.toStringAsFixed(1),
};

/// SPEC 8.4: built from camera.capabilities; unsupported settings are inactive with a hint.
class ControlPanel extends StatelessWidget {
  const ControlPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocBuilder<WatchCubit, WatchState>(
      buildWhen: (a, b) =>
          a.capabilities != b.capabilities || a.controls != b.controls,
      builder: (context, state) {
        final caps = state.capabilities;
        if (caps == null) return Text(l10n.deviceNoData);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (param, cap) in capabilityList(caps))
              ParamControl(
                key: Key('param-${cameraParamValues.reverse[param]}'),
                param: param,
                capability: cap,
                confirmed: state.controls[param],
              ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('reset-defaults'),
              onPressed: () => unawaited(_reset(context)),
              child: Text(l10n.resetDefaults),
            ),
          ],
        );
      },
    );
  }

  Future<void> _reset(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final results = await context.read<WatchCubit>().resetDefaults();
    for (final (param, result) in results) {
      if (!result.ok) {
        messenger.showSnackBar(
          SnackBar(content: Text(_failure(l10n, param, result))),
        );
      }
    }
  }
}

String _failure(AppLocalizations l10n, CameraParam param, SetResult result) =>
    l10n.cameraSetFailed(
      paramLabel(l10n, param),
      result.error == null
          ? l10n.cameraNoAnswer
          : cameraErrorCodeValues.reverse[result.error]!,
    );

/// One setting: «Авто / Ручной» (and presets for white balance), a slider sending camera.set 100 ms after it
/// stops moving; a refusal shows a toast and puts the slider back (SPEC 8.4).
class ParamControl extends StatefulWidget {
  const ParamControl({
    super.key,
    required this.param,
    required this.capability,
    this.confirmed,
  });

  final CameraParam param;
  final ParamCapability capability;

  /// The camera's current setting (camera.state).
  final CameraControl? confirmed;

  static const debounce = Duration(milliseconds: 100);

  @override
  State<ParamControl> createState() => _ParamControlState();
}

class _ParamControlState extends State<ParamControl> {
  late ControlMode _mode;
  double? _value;
  WhiteBalancePreset? _preset;
  Timer? _debounce;
  bool _dragging = false;
  String? _applied;

  ParamCapability get cap => widget.capability;

  @override
  void initState() {
    super.initState();
    _sync(widget.confirmed);
  }

  @override
  void didUpdateWidget(ParamControl old) {
    super.didUpdateWidget(old);
    if (!_dragging && _debounce?.isActive != true) _sync(widget.confirmed);
  }

  void _sync(CameraControl? control) {
    _mode =
        control?.mode ??
        (cap.modes.isNotEmpty ? cap.modes.first : ControlMode.AUTO);
    _value = control?.value ?? _value;
    _preset = control?.preset ?? _preset;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  CameraControl _control() => switch (_mode) {
    ControlMode.MANUAL => CameraControl(
      mode: _mode,
      value: _value ?? cap.min ?? 0,
    ),
    ControlMode.PRESET => CameraControl(
      mode: _mode,
      preset: _preset ?? cap.presets.firstOrNull,
    ),
    ControlMode.AUTO => CameraControl(mode: _mode),
  };

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cubit = context.read<WatchCubit>();
    final watch = Stopwatch()..start();
    setState(() => _applied = null);
    final result = await cubit.set(widget.param, _control());
    if (!mounted) return;
    if (result.ok) {
      setState(() => _applied = l10n.cameraApplied(watch.elapsedMilliseconds));
      return;
    }
    // Back to what the camera has; the toast says why.
    setState(() => _sync(widget.confirmed));
    messenger.showSnackBar(
      SnackBar(content: Text(_failure(l10n, widget.param, result))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = paramLabel(l10n, widget.param);
    if (!cap.supported) {
      return Tooltip(
        message: l10n.notSupportedHint,
        child: ListTile(
          dense: true,
          enabled: false,
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          trailing: Text(l10n.notSupported),
        ),
      );
    }
    final min = cap.min ?? 0;
    final max = cap.max ?? 1;
    final value = (_value ?? min).clamp(min, max);
    final step = cap.step;
    final divisions = step == null || step <= 0
        ? null
        : ((max - min) / step).round().clamp(1, 1000);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              if (_mode == ControlMode.MANUAL)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(valueLabel(widget.param, value)),
                ),
              if (cap.modes.length > 1)
                SegmentedButton<ControlMode>(
                  key: const Key('mode'),
                  showSelectedIcon: false,
                  segments: [
                    for (final mode in cap.modes)
                      ButtonSegment(
                        value: mode,
                        label: Text(modeLabel(l10n, mode)),
                      ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selected) {
                    setState(() => _mode = selected.first);
                    unawaited(_send());
                  },
                )
              else
                Text(modeLabel(l10n, _mode)),
            ],
          ),
          if (_mode == ControlMode.MANUAL)
            Slider(
              key: const Key('slider'),
              min: min,
              max: max,
              divisions: divisions,
              value: value,
              onChanged: (v) {
                setState(() {
                  _value = v;
                  _dragging = true;
                });
                _debounce?.cancel();
                _debounce = Timer(
                  ParamControl.debounce,
                  () => unawaited(_send()),
                );
              },
              onChangeEnd: (_) => _dragging = false,
            ),
          if (_mode == ControlMode.PRESET && cap.presets.isNotEmpty)
            DropdownButton<WhiteBalancePreset>(
              key: const Key('preset'),
              isExpanded: true,
              value: _preset ?? cap.presets.first,
              items: [
                for (final preset in cap.presets)
                  DropdownMenuItem(
                    value: preset,
                    child: Text(presetLabel(l10n, preset)),
                  ),
              ],
              onChanged: (preset) {
                setState(() => _preset = preset);
                unawaited(_send());
              },
            ),
          if (_applied != null)
            Text(
              _applied!,
              key: const Key('applied'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}
