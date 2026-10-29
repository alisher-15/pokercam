import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared/shared.dart';

import '../app.dart';
import '../store.dart';

/// Why pairing failed, as something the screen can say (keys of AppLocalizations).
enum PairingError { code, tooMany, unreachable, license, notOurs, other }

class PairingState {
  const PairingState({this.busy = false, this.error, this.errorCode = ''});

  final bool busy;
  final PairingError? error;

  /// The server's error code, for [PairingError.other].
  final String errorCode;
}

/// POST /device/pair with the code from the PC (SPEC 9.2); the result is this phone's refresh token.
class PairingCubit extends Cubit<PairingState> {
  PairingCubit(this.services, this.app) : super(const PairingState());

  final Services services;
  final AppCubit app;

  Future<void> scanned(String text) async {
    if (state.busy) return;
    final qr = PairingQr.parse(text);
    if (qr == null) {
      emit(const PairingState(error: PairingError.notOurs));
      return;
    }
    await pair(qr.apiUrl, qr.code);
  }

  Future<void> pair(String apiUrl, String code) async {
    if (state.busy) return;
    emit(const PairingState(busy: true));
    final url = PairingQr.normalizeApiUrl(apiUrl);
    final api = services.api(url);
    try {
      final me = await services.device.identity();
      final paired = await api.pairDevice(
        code: code.trim(),
        model: me.model,
        androidId: me.androidId,
      );
      await app.paired(
        Pairing(
          apiUrl: url,
          refreshToken: paired.refreshToken,
          deviceId: paired.deviceId,
          tableId: paired.tableId,
          clientId: paired.clientId,
        ),
      );
    } on ApiException catch (e) {
      services.log.warn('pairing failed', {'code': e.code, 'status': e.status});
      emit(PairingState(error: _error(e), errorCode: e.code));
    } finally {
      api.close();
    }
  }

  static PairingError _error(ApiException e) => switch (e.code) {
    _ when e.unreachable => PairingError.unreachable,
    'pairing_code_invalid' ||
    'pairing_code_used' ||
    'pairing_code_expired' => PairingError.code,
    'too_many_attempts' => PairingError.tooMany,
    'license_expired' ||
    'license_suspended' ||
    'no_license' => PairingError.license,
    _ => PairingError.other,
  };
}

/// Screen 1 of SPEC 6.1: scan the PC's QR code, or type the server address and the 6-digit code.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, this.replaced = false});

  final bool replaced;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  bool _manual = false;
  final _server = TextEditingController();
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(
      context.read<Services>().pairings.lastApiUrl().then((url) {
        if (url != null && mounted && _server.text.isEmpty) _server.text = url;
      }),
    );
  }

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider(
      create: (context) =>
          PairingCubit(context.read<Services>(), context.read<AppCubit>()),
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.pairingTitle)),
        body: BlocBuilder<PairingCubit, PairingState>(
          builder: (context, state) {
            final cubit = context.read<PairingCubit>();
            return ListView(
              key: const Key('pairing-screen'),
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.replaced) _Banner(text: l10n.pairingReplaced),
                if (state.error != null)
                  _Banner(
                    key: const Key('pairing-error'),
                    text: _errorText(l10n, state),
                  ),
                if (state.busy)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(l10n.pairingInProgress),
                      ],
                    ),
                  )
                else if (!_manual) ...[
                  Text(l10n.pairingScanHint),
                  const SizedBox(height: 12),
                  AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _scanner(
                        context,
                        (text) => unawaited(cubit.scanned(text)),
                        l10n,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const Key('pairing-manual'),
                    onPressed: () => setState(() => _manual = true),
                    child: Text(l10n.pairingManual),
                  ),
                ] else ...[
                  TextField(
                    key: const Key('pairing-server'),
                    controller: _server,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: l10n.pairingServerLabel,
                      hintText: l10n.pairingServerHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('pairing-code'),
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: l10n.pairingCodeLabel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('pairing-submit'),
                    onPressed: () =>
                        unawaited(cubit.pair(_server.text, _code.text)),
                    child: Text(l10n.pairingSubmit),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _manual = false),
                    child: Text(l10n.pairingScan),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  static Widget _scanner(
    BuildContext context,
    void Function(String) onCode,
    AppLocalizations l10n,
  ) =>
      context.read<Services>().scanner?.call(onCode) ??
      MobileScanner(
        onDetect: (capture) {
          final text = capture.barcodes.firstOrNull?.rawValue;
          if (text != null) onCode(text);
        },
        errorBuilder: (context, error) =>
            Center(child: Text(l10n.pairingCameraDenied)),
      );

  static String _errorText(AppLocalizations l10n, PairingState state) =>
      switch (state.error!) {
        PairingError.code => l10n.pairingErrorCode,
        PairingError.tooMany => l10n.pairingErrorTooMany,
        PairingError.unreachable => l10n.pairingErrorUnreachable,
        PairingError.license => l10n.pairingErrorLicense,
        PairingError.notOurs => l10n.pairingQrNotOurs,
        PairingError.other => l10n.pairingErrorOther(state.errorCode),
      };
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    ),
  );
}
