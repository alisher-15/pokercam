import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared/shared.dart';

import '../app.dart';
import '../store.dart';

class TablesState {
  const TablesState({this.tables, this.error});

  /// Null while loading.
  final List<TableInfo>? tables;
  final Object? error;
}

/// Screen 2 of SPEC 8.1: the club's tables with their cameras' status, refreshed every [every].
class TablesCubit extends Cubit<TablesState> {
  TablesCubit(
    this.services,
    this.app,
    this.connection, {
    this.every = const Duration(seconds: 15),
  }) : super(const TablesState());

  final Services services;
  final AppCubit app;
  final Connection connection;
  final Duration every;
  Timer? _timer;

  void start() {
    unawaited(load());
    _timer = Timer.periodic(every, (_) => unawaited(load()));
  }

  Future<void> load() async {
    final api = services.api(connection.apiUrl);
    try {
      final token = await api.token(connection.refreshToken);
      final tables = (await api.tables(token.accessToken)).tables
        ..sort((a, b) => a.number.compareTo(b.number));
      if (!isClosed) emit(TablesState(tables: tables));
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await app.signOut(revoked: true);
        return;
      }
      if (!isClosed) emit(TablesState(tables: state.tables, error: e));
    } on Object catch (e) {
      if (!isClosed) emit(TablesState(tables: state.tables, error: e));
    } finally {
      api.close();
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}

class TablesScreen extends StatelessWidget {
  const TablesScreen({super.key, required this.connection});

  final Connection connection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final app = context.read<AppCubit>();
    return BlocProvider(
      create: (context) =>
          TablesCubit(context.read<Services>(), app, connection)..start(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.tablesTitle),
          actions: [
            TextButton(
              key: const Key('sign-out'),
              onPressed: () => unawaited(app.signOut()),
              child: Text(l10n.signOut),
            ),
          ],
        ),
        body: BlocBuilder<TablesCubit, TablesState>(
          builder: (context, state) {
            final tables = state.tables;
            if (tables == null && state.error == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              key: const Key('tables-screen'),
              padding: const EdgeInsets.all(16),
              children: [
                if (state.error != null)
                  ListTile(
                    title: Text(
                      apiErrorText(l10n, state.error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: () =>
                          unawaited(context.read<TablesCubit>().load()),
                      child: Text(l10n.retry),
                    ),
                  ),
                if (tables != null && tables.isEmpty)
                  ListTile(title: Text(l10n.tablesEmpty)),
                for (final table in tables ?? const <TableInfo>[])
                  _TableTile(table: table, connection: connection),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TableTile extends StatelessWidget {
  const _TableTile({required this.table, required this.connection});

  final TableInfo table;
  final Connection connection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final seen = table.cameraLastSeenAt;
    final status = table.cameraOnline
        ? l10n.tableCameraOnline
        : seen != null
        ? l10n.tableCameraLastSeen(
            DateFormat.yMd(l10n.localeName).add_Hm().format(seen.toLocal()),
          )
        : l10n.tableCameraOffline;
    return Card(
      child: ListTile(
        key: Key('table-${table.number}'),
        leading: Icon(
          Icons.videocam,
          color: table.cameraOnline ? Colors.redAccent : null,
        ),
        title: Text(l10n.tableName(table.number)),
        subtitle: Text(status),
        onTap: () => context.read<AppCubit>().openTable(table),
        trailing: Wrap(
          spacing: 8,
          children: [
            TextButton(
              key: Key('table-${table.number}-pair'),
              onPressed: () => showPairingDialog(context, connection, table),
              child: Text(l10n.pairPhone),
            ),
            TextButton(
              key: Key('table-${table.number}-window'),
              onPressed: () =>
                  unawaited(context.read<Services>().openWindow(table.id)),
              child: Text(l10n.tableOpenWindow),
            ),
            FilledButton(
              key: Key('table-${table.number}-open'),
              onPressed: () => context.read<AppCubit>().openTable(table),
              child: Text(l10n.tableOpen),
            ),
          ],
        ),
      ),
    );
  }
}

/// SPEC 8.1: the QR code and the 6-digit code a new phone pairs with (5 minutes).
Future<void> showPairingDialog(
  BuildContext context,
  Connection connection,
  TableInfo table,
) => showDialog<void>(
  context: context,
  builder: (_) => RepositoryProvider.value(
    value: context.read<Services>(),
    child: PairingDialog(connection: connection, table: table),
  ),
);

class PairingDialog extends StatefulWidget {
  const PairingDialog({
    super.key,
    required this.connection,
    required this.table,
  });

  final Connection connection;
  final TableInfo table;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  PairingCodeResponse? _code;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    setState(() {
      _code = null;
      _error = null;
    });
    final api = context.read<Services>().api(widget.connection.apiUrl);
    try {
      final token = await api.token(widget.connection.refreshToken);
      final code = await api.pairingCode(token.accessToken, widget.table.id);
      if (mounted) setState(() => _code = code);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final code = _code;
    return AlertDialog(
      key: const Key('pairing-dialog'),
      title: Text(l10n.pairPhoneTitle(widget.table.number)),
      content: SizedBox(
        width: 320,
        child: _error != null
            ? Text(apiErrorText(l10n, _error!))
            : code == null
            ? const SizedBox(
                height: 320,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.pairPhoneHint, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  ColoredBox(
                    color: Colors.white,
                    child: QrImageView(
                      key: const Key('pairing-qr'),
                      data: code.qrPayload,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    code.code,
                    key: const Key('pairing-code'),
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      letterSpacing: 6,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.pairPhoneServer(widget.connection.apiUrl)),
                  Text(
                    l10n.pairPhoneExpires(
                      DateFormat.Hm(l10n.localeName)
                          .format(code.expiresAt.toLocal()),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => unawaited(_fetch()),
          child: Text(l10n.pairPhoneNewCode),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}
