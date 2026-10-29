import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared/shared.dart';

import 'media.dart';
import 'platform/camera2.dart';
import 'platform/device.dart';
import 'store.dart';
import 'ui/broadcast_screen.dart';
import 'ui/pairing_screen.dart';
import 'ui/preflight_screen.dart';

/// Everything that talks to the outside world, injected so tests can replace it.
class Services {
  Services({
    required this.pairings,
    required this.settings,
    required this.camera,
    required this.device,
    required this.publisher,
    required this.log,
    ApiClient Function(String apiUrl)? api,
    this.scanner,
  }) : api = api ?? ApiClient.new;

  final PairingStore pairings;
  final SettingsStore settings;
  final CameraControlApi camera;
  final DeviceApi device;
  final Publisher publisher;
  final JsonLog log;
  final ApiClient Function(String apiUrl) api;

  /// The QR scanner widget; null means the camera one (mobile_scanner). Tests put a stand-in here.
  final Widget Function(void Function(String text) onCode)? scanner;
}

enum Screen { loading, pairing, preflight, broadcast }

class AppState {
  const AppState(this.screen, {this.pairing, this.replaced = false});

  final Screen screen;
  final Pairing? pairing;

  /// Back on the pairing screen because the server dropped this phone (SPEC 6.4).
  final bool replaced;
}

/// Which screen is up (SPEC 6.1): pairing only for an unpaired phone, then the check, then the broadcast.
class AppCubit extends Cubit<AppState> {
  AppCubit(this.services) : super(const AppState(Screen.loading));

  final Services services;

  Future<void> start() async {
    final pairing = await services.pairings.load();
    emit(
      pairing == null
          ? const AppState(Screen.pairing)
          : AppState(Screen.preflight, pairing: pairing),
    );
  }

  Future<void> paired(Pairing pairing) async {
    await services.pairings.save(pairing);
    // Settings belong to the camera of a table: a new pairing starts from automatic.
    await services.settings.clear();
    services.log.info('paired', {
      'table_id': pairing.tableId,
      'device_id': pairing.deviceId,
    });
    emit(AppState(Screen.preflight, pairing: pairing));
  }

  void startBroadcast() =>
      emit(AppState(Screen.broadcast, pairing: state.pairing));

  void stopBroadcast() =>
      emit(AppState(Screen.preflight, pairing: state.pairing));

  /// Unpaired by hand, replaced by another phone or revoked in the admin panel.
  Future<void> unpaired({bool replaced = false}) async {
    await services.pairings.clear();
    await services.publisher.closeCamera();
    emit(AppState(Screen.pairing, replaced: replaced));
  }
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key, required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) => RepositoryProvider.value(
    value: services,
    child: BlocProvider(
      create: (_) => AppCubit(services)..start(),
      child: MaterialApp(
        onGenerateTitle: (context) =>
            AppLocalizations.of(context).cameraAppTitle,
        theme: buildTheme(neutralColors),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocBuilder<AppCubit, AppState>(
          builder: (context, state) => switch (state.screen) {
            Screen.loading => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
            Screen.pairing => PairingScreen(replaced: state.replaced),
            Screen.preflight => PreflightScreen(
              key: ValueKey(state.pairing!.deviceId),
              pairing: state.pairing!,
            ),
            Screen.broadcast => BroadcastScreen(pairing: state.pairing!),
          },
        ),
      ),
    ),
  );
}
