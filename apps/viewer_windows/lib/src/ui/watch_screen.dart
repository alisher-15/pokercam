import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared/shared.dart';

import '../app.dart';
import '../session.dart';
import '../store.dart';
import 'control_panel.dart';
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

  /// Each device.alert as it arrives, for the toast.
  Stream<AlertEntry> get alerts => _alerts.stream;

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
    _api?.close();
    return super.close();
  }
}

class WatchScreen extends StatelessWidget {
  const WatchScreen({super.key, required this.connection, required this.table});

  final Connection connection;
  final TableInfo table;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final app = context.read<AppCubit>();
    return BlocProvider(
      create: (context) =>
          WatchCubit(context.read<Services>(), app, connection, table)..start(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.tableName(table.number)),
          actions: [
            TextButton(
              key: const Key('watch-pair'),
              onPressed: () => showPairingDialog(context, connection, table),
              child: Text(l10n.pairPhone),
            ),
            TextButton(
              key: const Key('watch-tables'),
              onPressed: app.showTables,
              child: Text(l10n.tablesTitle),
            ),
          ],
        ),
        body: const _AlertToasts(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _VideoArea()),
              SizedBox(width: 360, child: _SidePanel()),
            ],
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

class _VideoArea extends StatelessWidget {
  const _VideoArea();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final services = context.read<Services>();
    return BlocBuilder<WatchCubit, WatchState>(
      builder: (context, state) {
        final stream = state.stream;
        final blocked = state.phase == WatchPhase.blocked;
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
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (stream != null && !blocked) services.video(stream),
              if (message != null)
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              if (state.phase == WatchPhase.live)
                Positioned(
                  left: 12,
                  top: 12,
                  child: Container(
                    key: const Key('watch-live'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      l10n.liveBadge,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              if (grace != null && !blocked)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    key: const Key('watch-grace'),
                    color: Colors.amber.shade700,
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      l10n.bannerLicenseGrace(
                        DateFormat.yMd(l10n.localeName).add_Hm().format(grace),
                      ),
                      style: const TextStyle(color: Colors.black),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
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
