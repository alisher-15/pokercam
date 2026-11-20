import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared/shared.dart';

import '../app.dart';
import '../dvr/controller.dart';
import '../session.dart';
import '../store.dart';
import 'control_panel.dart';
import 'dvr_view.dart';
import 'tables_screen.dart';

/// Screen 3 of SPEC 8.1: the table's camera on the left, the control panel on the right.
class WatchCubit extends Cubit<WatchState> {
  WatchCubit(this.services, this.app, this.connection, this.table)
    : super(const WatchState());

  final Services services;
  final AppCubit app;
  final Connection connection;
  final TableInfo table;
  ApiClient? _api;
  TableSession? _session;
  StreamSubscription<WatchState>? _states;
  StreamSubscription<AlertEntry>? _alertSubscription;
  final _alerts = StreamController<AlertEntry>.broadcast();
  Future<DvrController?>? _makingDvr;

  /// The table's DVR, once someone has used it (its player is made then).
  final dvr = ValueNotifier<DvrController?>(null);

  /// Each device.alert as it arrives, for the toast.
  Stream<AlertEntry> get alerts => _alerts.stream;

  DvrSource _dvrSource(DvrAccess access) => DvrSource(
    playlist: access.playlist,
    headers: access.headers,
    get: services.dvrGet,
  );

  /// The DVR for the keys: null while media-server has said nothing about one (no H.264 camera yet).
  Future<DvrController?> useDvr() {
    final existing = dvr.value;
    if (existing != null) return Future.value(existing);
    final access = state.dvr;
    final session = _session;
    if (access == null || session == null) return Future.value();
    return _makingDvr ??= () async {
      final player = await services.dvrPlayer(session.log);
      if (isClosed) {
        await player.dispose();
        return null;
      }
      final controller = DvrController(
        player: player,
        source: _dvrSource(access),
        log: session.log,
      );
      dvr.value = controller;
      return controller;
    }();
  }

  Future<void> start() async {
    final api = services.api(connection.apiUrl);
    _api = api;
    final session = TableSession(
      tableId: table.id,
      tokens: (tableId) => api.token(connection.refreshToken, tableId: tableId),
      subscriber: services.subscriber(),
      log: services.log,
      connect: services.connect,
    );
    _session = session;
    _states = session.states.listen((s) {
      final access = s.dvr;
      // A reconnection brings a new token.
      if (access != null) dvr.value?.source = _dvrSource(access);
      if (!isClosed) emit(s);
    });
    _alertSubscription = session.alerts.listen(_alerts.add);
    final ended = await session.run();
    if (ended == WatchPhase.unauthorized) await app.signOut(revoked: true);
  }

  Future<SetResult> set(CameraParam param, CameraControl control) =>
      _session?.set(param, control) ?? Future.value(const SetResult(ok: false));

  /// SPEC 8.4 «Сбросить по умолчанию»: every supported setting back to the camera's default.
  Future<List<(CameraParam, SetResult)>> resetDefaults() async {
    final caps = state.capabilities;
    if (caps == null) return const [];
    final results = <(CameraParam, SetResult)>[];
    for (final (param, cap) in capabilityList(caps)) {
      if (!cap.supported) continue;
      final control =
          cap.paramCapabilityDefault ??
          (cap.modes.contains(ControlMode.AUTO)
              ? CameraControl(mode: ControlMode.AUTO)
              : null);
      if (control == null) continue;
      results.add((param, await set(param, control)));
    }
    return results;
  }

  @override
  Future<void> close() async {
    await _states?.cancel();
    await _alertSubscription?.cancel();
    await _alerts.close();
    await _session?.stop();
    await (await _makingDvr)?.dispose();
    dvr.dispose();
    _api?.close();
    return super.close();
  }
}

class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.connection, required this.table});

  final Connection connection;
  final TableInfo table;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

/// SPEC 8.3: the DVR keys go to one focus node of this screen. Its buttons and sliders take no keyboard focus
/// (the mouse works as ever): otherwise the arrows would also move the focus and Space would press the
/// focused button.
class _WatchScreenState extends State<WatchScreen> {
  final _video = GlobalKey<_VideoAreaState>();
  final _keys = FocusNode(debugLabel: 'dvr-keys');

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final app = context.read<AppCubit>();
    final connection = widget.connection;
    final table = widget.table;
    return BlocProvider(
      create: (context) =>
          WatchCubit(context.read<Services>(), app, connection, table)..start(),
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: (node, event) =>
            _video.currentState?.onKey(event) ?? KeyEventResult.ignored,
        // A click anywhere on the screen brings the keys back here (after a dialog, say).
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _keys.requestFocus(),
          child: ExcludeFocus(
            child: Scaffold(
              appBar: AppBar(
                title: Text(l10n.tableName(table.number)),
                actions: [
                  TextButton(
                    key: const Key('watch-pair'),
                    onPressed: () =>
                        showPairingDialog(context, connection, table),
                    child: Text(l10n.pairPhone),
                  ),
                  TextButton(
                    key: const Key('watch-tables'),
                    onPressed: app.showTables,
                    child: Text(l10n.tablesTitle),
                  ),
                ],
              ),
              body: _AlertToasts(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _VideoArea(key: _video)),
                    const SizedBox(width: 360, child: _SidePanel()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// SPEC 8.4: each device.alert pops up as a toast (the journal keeps the last 50).
class _AlertToasts extends StatefulWidget {
  const _AlertToasts({required this.child});

  final Widget child;

  @override
  State<_AlertToasts> createState() => _AlertToastsState();
}

class _AlertToastsState extends State<_AlertToasts> {
  StreamSubscription<AlertEntry>? _alerts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _alerts ??= context.read<WatchCubit>().alerts.listen(_show);
  }

  void _show(AlertEntry alert) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          alertText(AppLocalizations.of(context), alert.messageKey),
        ),
        backgroundColor: alert.level == AlertLevel.CRITICAL
            ? Theme.of(context).colorScheme.error
            : null,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_alerts?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The camera live, with the DVR over it while behind (SPEC 8.2): the live video keeps playing underneath, so
/// LIVE is back at once; going behind, the live frame stays frozen until the DVR shows its moment.
class _VideoArea extends StatefulWidget {
  const _VideoArea({super.key});

  @override
  State<_VideoArea> createState() => _VideoAreaState();
}

class _VideoAreaState extends State<_VideoArea> {
  final _liveKey = GlobalKey();
  ui.Image? _frozen;
  DateTime? _toldUnavailable;

  @override
  void dispose() {
    _frozen?.dispose();
    super.dispose();
  }

  /// A key on the watch screen: a DVR key is used here, any other goes on (a text field keeps its own keys).
  KeyEventResult onKey(KeyEvent event) {
    final action = dvrAction(
      event,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );
    if (action == null || !mounted || focusInTextField()) {
      return KeyEventResult.ignored;
    }
    unawaited(_run(action));
    return KeyEventResult.handled;
  }

  Future<void> _run(Future<void> Function(DvrController dvr) action) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final dvr = await context.read<WatchCubit>().useDvr();
    if (dvr == null) {
      final now = DateTime.now();
      final told = _toldUnavailable;
      if (told == null || now.difference(told) > const Duration(seconds: 5)) {
        _toldUnavailable = now;
        messenger.showSnackBar(SnackBar(content: Text(l10n.dvrUnavailable)));
      }
      return;
    }
    if (dvr.view.live) _freeze();
    try {
      await action(dvr);
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(l10n.dvrFailed)));
    }
  }

  /// The live frame as it is now, shown until the DVR player has its first frame.
  void _freeze() {
    final boundary = _liveKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return;
    final ui.Image image;
    try {
      image = boundary.toImageSync();
    } on Object {
      // Not painted yet: nothing to freeze.
      return;
    }
    setState(() {
      _frozen?.dispose();
      _frozen = image;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<WatchCubit>();
    return ValueListenableBuilder<DvrController?>(
      valueListenable: cubit.dvr,
      // The stream only says when to draw again: the controller may have moved on before this subscribed.
      builder: (context, dvr, _) => StreamBuilder<DvrView>(
        stream: dvr?.views,
        builder: (context, _) => BlocBuilder<WatchCubit, WatchState>(
          builder: (context, state) =>
              _build(context, state, dvr, dvr?.view ?? const DvrView()),
        ),
      ),
    );
  }

  Widget _build(
    BuildContext context,
    WatchState state,
    DvrController? dvr,
    DvrView view,
  ) {
    final l10n = AppLocalizations.of(context);
    final services = context.read<Services>();
    final stream = state.stream;
    final blocked = state.phase == WatchPhase.blocked;
    final behind = !view.live && dvr != null && !blocked;
    final grace = state.license == RoomLicenseStatus.GRACE
        ? state.graceUntil
        : null;
    final message = switch (state.phase) {
      WatchPhase.connecting => l10n.statusConnecting,
      WatchPhase.reconnecting => l10n.statusReconnecting,
      WatchPhase.blocked => l10n.errorLicense,
      WatchPhase.roomFull => l10n.watchRoomFull,
      WatchPhase.waiting || WatchPhase.stopped || WatchPhase.unauthorized =>
        state.cameraOfflineSince != null
            ? l10n.watchCameraOfflineSince(
                DateFormat.yMd(l10n.localeName)
                    .add_Hm()
                    .format(state.cameraOfflineSince!),
              )
            : l10n.watchWaiting,
      WatchPhase.live => null,
    };
    return RepaintBoundary(
      key: const Key('video-area'),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (stream != null && !blocked)
              RepaintBoundary(key: _liveKey, child: services.video(stream)),
            // SPEC 8.5: the DVR stays available while the camera is offline, until the buffer runs out.
            if (behind) ...[
              Positioned.fill(
                child: Opacity(
                  key: const Key('dvr-video'),
                  opacity: view.showing ? 1 : 0,
                  child: dvr.player.view(),
                ),
              ),
              if (!view.showing && _frozen != null)
                Positioned.fill(
                  child: RawImage(
                    key: const Key('dvr-frozen'),
                    image: _frozen,
                    fit: BoxFit.fill,
                  ),
                ),
            ],
            if (message != null && !behind)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.phase == WatchPhase.connecting ||
                        state.phase == WatchPhase.reconnecting)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: CircularProgressIndicator(),
                      ),
                    Text(
                      message,
                      key: const Key('watch-message'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
              ),
            if (state.phase == WatchPhase.live || behind)
              Positioned(
                left: 12,
                top: 12,
                child: DvrIndicator(view: behind ? view : const DvrView()),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (grace != null && !blocked)
                    Container(
                      key: const Key('watch-grace'),
                      color: Colors.amber.shade700,
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        l10n.bannerLicenseGrace(
                          DateFormat.yMd(l10n.localeName)
                              .add_Hm()
                              .format(grace),
                        ),
                        style: const TextStyle(color: Colors.black),
                      ),
                    ),
                  if (state.dvr != null && !blocked)
                    DvrBar(
                      view: behind ? view : DvrView(timeline: view.timeline),
                      onLive: () => unawaited(dvr?.goLive()),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocBuilder<WatchCubit, WatchState>(
      builder: (context, state) => ListView(
        key: const Key('watch-panel'),
        padding: const EdgeInsets.all(12),
        children: [
          _Section(title: l10n.panelCamera, child: const ControlPanel()),
          _Section(
            title: l10n.panelDevice,
            child: DeviceStatus(state: state),
          ),
          _Section(
            title: l10n.panelAlerts,
            child: _AlertJournal(alerts: state.alerts),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

/// SPEC 8.4: battery, temperature, network, bitrate, fps and the connection's state.
class DeviceStatus extends StatelessWidget {
  const DeviceStatus({super.key, required this.state});

  final WatchState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = state.telemetry;
    final receive = state.receive;
    final connection = switch (state.phase) {
      WatchPhase.live => [
        l10n.connectionLive,
        if (receive != null) ...[
          '${receive.width}×${receive.height}',
          l10n.statsFps(receive.fps.round()),
          ?receive.codec?.replaceFirst('video/', ''),
        ],
      ].join(', '),
      WatchPhase.reconnecting ||
      WatchPhase.connecting => l10n.statusReconnecting,
      _ => l10n.connectionOffline,
    };
    final rows = <(String, String)>[
      (l10n.deviceConnection, connection),
      if (t == null)
        (l10n.panelDevice, l10n.deviceNoData)
      else ...[
        (
          l10n.deviceBattery,
          t.charging
              ? l10n.deviceCharging(t.batteryPct)
              : l10n.deviceBatteryValue(t.batteryPct),
        ),
        (
          l10n.deviceTemperature,
          l10n.deviceTemperatureValue(t.tempC.toStringAsFixed(1)),
        ),
        (
          l10n.deviceNetwork,
          [
            switch (t.network.type) {
              NetworkType.WIFI => l10n.networkWifi,
              NetworkType.CELLULAR => l10n.networkCellular,
              NetworkType.ETHERNET => l10n.networkEthernet,
              NetworkType.NONE => l10n.networkNone,
            },
            if (t.network.rssi != null) l10n.deviceSignal(t.network.rssi!),
            if (t.network.rttMs != null) l10n.deviceRtt(t.network.rttMs!),
          ].join(', '),
        ),
        (l10n.deviceBitrate, l10n.statsBitrate(t.stream.bitrateKbps)),
        (l10n.deviceFps, l10n.statsFps(t.stream.fps.round())),
        (l10n.deviceDropped, '${t.stream.droppedFrames}'),
      ],
    ];
    return Column(
      key: const Key('device-status'),
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(label)),
                Flexible(child: Text(value, textAlign: TextAlign.right)),
              ],
            ),
          ),
      ],
    );
  }
}

class _AlertJournal extends StatelessWidget {
  const _AlertJournal({required this.alerts});

  final List<AlertEntry> alerts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (alerts.isEmpty) return Text(l10n.alertsEmpty);
    final time = DateFormat.Hms(l10n.localeName);
    return Column(
      key: const Key('alert-journal'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final alert in alerts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${time.format(alert.at)}  ${alertText(l10n, alert.messageKey)}',
              style: alert.level == AlertLevel.CRITICAL
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// The text of a device.alert's message_key (the camera app's keys); an unknown key as it is.
String alertText(AppLocalizations l10n, String key) => switch (key) {
  'alertOverheating' || 'alertOverheatingWarning' => l10n.alertOverheating,
  'alertOverheatingCritical' => l10n.alertOverheatingCritical,
  'alertCooledDown' => l10n.alertCooledDown,
  'alertLowBattery' => l10n.alertLowBattery,
  'alertBatteryCritical' => l10n.alertBatteryCritical,
  _ => key,
};
