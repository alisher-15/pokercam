import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared/shared.dart';

import '../app.dart';
import '../policy.dart';
import '../session.dart';
import '../store.dart';
import '../tokens.dart';
import 'preview.dart';

/// Runs the [BroadcastSession] for the screen: foreground service and screen on while it lives (SPEC 6.3).
class BroadcastCubit extends Cubit<SessionState> {
  BroadcastCubit(this.services, this.app, this.pairing, this.l10n)
    : super(const SessionState());

  final Services services;
  final AppCubit app;
  final Pairing pairing;
  final AppLocalizations l10n;
  BroadcastSession? _session;
  ApiClient? _api;
  StreamSubscription<SessionState>? _states;

  Future<void> start() async {
    final api = services.api(pairing.apiUrl);
    _api = api;
    final session = BroadcastSession(
      pairing: pairing,
      tokens: TokenSource(api, pairing.refreshToken),
      publisher: services.publisher,
      camera: services.camera,
      device: services.device,
      settings: services.settings,
      log: services.log,
    );
    _session = session;
    _states = session.states.listen((s) {
      if (!isClosed) emit(s);
    });
    await services.device.keepScreenOn(true);
    await services.device.startService(
      title: l10n.serviceTitle,
      text: l10n.serviceText,
      channel: l10n.serviceChannel,
    );
    final ended = await session.run();
    await services.device.stopService();
    await services.device.keepScreenOn(false);
    api.close();
    if (ended == SessionPhase.unpaired) await app.unpaired(replaced: true);
  }

  Future<void> stop() async {
    await _session?.stop();
    app.stopBroadcast();
  }

  @override
  Future<void> close() async {
    await _states?.cancel();
    await _session?.stop();
    _api?.close();
    return super.close();
  }
}

/// Screen 3 of SPEC 6.1: preview, LIVE, bitrate, fps, battery, temperature, network; banners over the preview.
class BroadcastScreen extends StatelessWidget {
  const BroadcastScreen({super.key, required this.pairing});

  final Pairing pairing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider(
      create: (context) => BroadcastCubit(
        context.read<Services>(),
        context.read<AppCubit>(),
        pairing,
        l10n,
      )..start(),
      child: BlocBuilder<BroadcastCubit, SessionState>(
        builder: (context, state) {
          final stream = context.read<Services>().publisher.stream;
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Stack(
                children: [
                  if (stream != null)
                    Positioned.fill(child: Preview(stream: stream)),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _StatusBadge(state: state, l10n: l10n),
                  ),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: _Figures(state: state, l10n: l10n),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 72,
                    child: Column(children: _banners(context, state, l10n)),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FilledButton.tonalIcon(
                      key: const Key('broadcast-stop'),
                      onPressed: () =>
                          unawaited(context.read<BroadcastCubit>().stop()),
                      icon: const Icon(Icons.stop),
                      label: Text(l10n.stopStreaming),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static List<Widget> _banners(
    BuildContext context,
    SessionState state,
    AppLocalizations l10n,
  ) {
    final date = DateFormat.yMd(
      Localizations.localeOf(context).toLanguageTag(),
    );
    return [
      if (state.phase == SessionPhase.reconnecting)
        _Banner(l10n.bannerNoConnection, critical: true),
      if (state.phase == SessionPhase.blocked)
        _Banner(l10n.bannerLicenseBlocked, critical: true),
      if (state.license == RoomLicenseStatus.GRACE && state.graceUntil != null)
        _Banner(l10n.bannerLicenseGrace(date.format(state.graceUntil!))),
      for (final alert in state.banners)
        _Banner(
          alertText(l10n, alert),
          critical: alert.level == AlertLevel.CRITICAL,
        ),
    ];
  }
}

/// The localized text of a device.alert's message_key.
String alertText(AppLocalizations l10n, Alert alert) =>
    switch (alert.messageKey) {
      'alertOverheating' => l10n.alertOverheating,
      'alertOverheatingCritical' => l10n.alertOverheatingCritical,
      'alertCooledDown' => l10n.alertCooledDown,
      'alertLowBattery' => l10n.alertLowBattery,
      'alertBatteryCritical' => l10n.alertBatteryCritical,
      _ => alert.messageKey,
    };

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.state, required this.l10n});

  final SessionState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final live = state.phase == SessionPhase.live;
    final text = switch (state.phase) {
      SessionPhase.live => l10n.liveBadge,
      SessionPhase.reconnecting => l10n.statusReconnecting,
      SessionPhase.blocked => l10n.licenseBlocked,
      _ => l10n.statusConnecting,
    };
    return DecoratedBox(
      key: const Key('broadcast-status'),
      decoration: BoxDecoration(
        color: live ? Colors.red : Colors.grey.shade800,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _Figures extends StatelessWidget {
  const _Figures({required this.state, required this.l10n});

  final SessionState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final stats = state.stats;
    final device = state.device;
    final lines = [
      if (stats != null) l10n.statsBitrate(stats.bitrateKbps),
      if (stats != null) l10n.statsFps(stats.fps.round()),
      if (device != null) l10n.statsBattery(device.batteryPct),
      if (device != null)
        l10n.statsTemperature(device.tempC.toStringAsFixed(1)),
      if (device != null)
        switch (device.network.type) {
          NetworkType.WIFI => l10n.networkWifi,
          NetworkType.CELLULAR => l10n.networkCellular,
          NetworkType.ETHERNET => l10n.networkEthernet,
          NetworkType.NONE => l10n.networkNone,
        },
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final line in lines)
              Text(line, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {this.critical = false});

  final String text;
  final bool critical;

  @override
  Widget build(BuildContext context) => Card(
    color: critical ? Colors.red.shade700 : Colors.orange.shade700,
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Text(text, style: const TextStyle(color: Colors.white)),
    ),
  );
}
