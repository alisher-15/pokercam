import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart'
    show MediaStream;
import 'package:shared/shared.dart';

import 'store.dart';
import 'subscriber.dart';
import 'ui/activation_screen.dart';
import 'ui/tables_screen.dart';
import 'ui/video.dart';
import 'ui/watch_screen.dart';

/// Everything that talks to the outside world, injected so tests can replace it.
class Services {
  Services({
    required this.store,
    required this.log,
    required this.subscriber,
    ApiClient Function(String apiUrl)? api,
    Future<ControlSocket> Function(String url, String tableId)? connect,
    Future<void> Function(String tableId)? openWindow,
    Widget Function(MediaStream stream)? video,
  }) : api = api ?? ApiClient.new,
       connect = connect ?? ControlSocket.connect,
       openWindow = openWindow ?? openTableWindow,
       video = video ?? ((stream) => LiveVideo(stream: stream));

  final ConnectionStore store;
  final JsonLog log;

  /// A new video subscriber for each table session.
  final Subscriber Function() subscriber;
  final ApiClient Function(String apiUrl) api;
  final Future<ControlSocket> Function(String url, String tableId) connect;

  /// SPEC 8: one window per table; another table opens in a new window (a new process of this app).
  final Future<void> Function(String tableId) openWindow;

  /// The live picture of a stream; tests put a stand-in here (the real one needs the WebRTC plugin).
  final Widget Function(MediaStream stream) video;
}

/// Starts this app again for [tableId]: `viewer_windows.exe --table <id>`.
Future<void> openTableWindow(String tableId) => Process.start(
  Platform.resolvedExecutable,
  ['--table', tableId],
  mode: ProcessStartMode.detached,
);

enum Screen { loading, activation, tables, watch }

class AppState {
  const AppState(
    this.screen, {
    this.connection,
    this.table,
    this.revoked = false,
  });

  final Screen screen;
  final Connection? connection;
  final TableInfo? table;

  /// Back on activation because the backend no longer knows this PC.
  final bool revoked;
}

/// Which screen is up (SPEC 8.1): activation once, then the tables, then a table.
class AppCubit extends Cubit<AppState> {
  AppCubit(this.services, {this.initialTable})
    : super(const AppState(Screen.loading));

  final Services services;

  /// The table this window was opened for (`--table`).
  final String? initialTable;

  Future<void> start() async {
    final connection = await services.store.load();
    if (connection == null) {
      emit(const AppState(Screen.activation));
      return;
    }
    if (initialTable != null) {
      final table = await _findTable(connection, initialTable!);
      if (table != null) {
        emit(AppState(Screen.watch, connection: connection, table: table));
        return;
      }
    }
    emit(AppState(Screen.tables, connection: connection));
  }

  Future<TableInfo?> _findTable(Connection connection, String id) async {
    final api = services.api(connection.apiUrl);
    try {
      final token = await api.token(connection.refreshToken);
      final tables = await api.tables(token.accessToken);
      return tables.tables.where((t) => t.id == id).firstOrNull;
    } on Object catch (e) {
      services.log.warn('table lookup failed', {'error': '$e'});
      return null;
    } finally {
      api.close();
    }
  }

  Future<void> activated(Connection connection) async {
    await services.store.save(connection);
    services.log.info('activated', {
      'viewer_id': connection.viewerId,
      'client_id': connection.clientId,
    });
    emit(AppState(Screen.tables, connection: connection));
  }

  void openTable(TableInfo table) =>
      emit(AppState(Screen.watch, connection: state.connection, table: table));

  void showTables() =>
      emit(AppState(Screen.tables, connection: state.connection));

  /// Signed out by hand, or revoked in the admin panel.
  Future<void> signOut({bool revoked = false}) async {
    await services.store.clear();
    emit(AppState(Screen.activation, revoked: revoked));
  }
}

class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key, required this.services, this.initialTable});

  final Services services;
  final String? initialTable;

  @override
  Widget build(BuildContext context) => RepositoryProvider.value(
    value: services,
    child: BlocProvider(
      create: (_) => AppCubit(services, initialTable: initialTable)..start(),
      child: MaterialApp(
        onGenerateTitle: (context) =>
            AppLocalizations.of(context).viewerAppTitle,
        theme: buildTheme(neutralColors),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocBuilder<AppCubit, AppState>(
          builder: (context, state) => switch (state.screen) {
            Screen.loading => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
            Screen.activation => ActivationScreen(revoked: state.revoked),
            Screen.tables => TablesScreen(connection: state.connection!),
            Screen.watch => WatchScreen(
              key: ValueKey(state.table!.id),
              connection: state.connection!,
              table: state.table!,
            ),
          },
        ),
      ),
    ),
  );
}

/// Text for an API failure on any screen (SPEC 8.5: the user sees what to do, not a stack trace).
String apiErrorText(AppLocalizations l10n, Object error) {
  if (error is! ApiException) return l10n.errorOther('$error');
  if (error.unreachable) return l10n.errorUnreachable;
  return switch (error.code) {
    'invalid_activation_key' => l10n.activationErrorKey,
    'too_many_attempts' => l10n.errorTooMany,
    'invalid_refresh_token' || 'access_revoked' => l10n.errorRevoked,
    'license_expired' ||
    'license_suspended' ||
    'no_license' => l10n.errorLicense,
    _ => l10n.errorOther(error.code),
  };
}
