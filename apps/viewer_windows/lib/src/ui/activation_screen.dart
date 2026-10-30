import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared/shared.dart';

import '../app.dart';
import '../store.dart';

class ActivationState {
  const ActivationState({this.busy = false, this.error});

  final bool busy;

  /// The failure, as the exception that caused it (shown by [apiErrorText]).
  final Object? error;
}

/// Screen 1 of SPEC 8.1: the club's activation key, once per computer.
class ActivationCubit extends Cubit<ActivationState> {
  ActivationCubit(this.services, this.app) : super(const ActivationState());

  final Services services;
  final AppCubit app;

  Future<void> activate(String server, String key, String name) async {
    if (state.busy) return;
    emit(const ActivationState(busy: true));
    final url = PairingQr.normalizeApiUrl(server);
    final api = services.api(url);
    try {
      final activated = await api.activate(
        activationKey: key.trim(),
        machineId: await services.store.machineId(),
        name: name.trim().isEmpty ? null : name.trim(),
      );
      // A first token proves the license lets this club in (check_license, SPEC 8.1).
      final token = await api.token(activated.refreshToken);
      await api.license(token.accessToken);
      await app.activated(
        Connection(
          apiUrl: url,
          refreshToken: activated.refreshToken,
          viewerId: activated.viewerId,
          clientId: activated.clientId,
        ),
      );
    } on Object catch (e) {
      services.log.warn('activation failed', {'error': '$e'});
      emit(ActivationState(error: e));
    } finally {
      api.close();
    }
  }
}

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key, this.revoked = false});

  final bool revoked;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _server = TextEditingController();
  final _key = TextEditingController();
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(
      context.read<Services>().store.lastApiUrl().then((url) {
        if (url != null && mounted && _server.text.isEmpty) _server.text = url;
      }),
    );
  }

  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_name.text.isEmpty) _name.text = l10n.activationNameDefault;
    return BlocProvider(
      create: (context) =>
          ActivationCubit(context.read<Services>(), context.read<AppCubit>()),
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.activationTitle)),
        body: BlocBuilder<ActivationCubit, ActivationState>(
          builder: (context, state) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                key: const Key('activation-screen'),
                padding: const EdgeInsets.all(24),
                shrinkWrap: true,
                children: [
                  if (widget.revoked && state.error == null)
                    _Message(l10n.errorRevoked),
                  if (state.error != null)
                    _Message(
                      apiErrorText(l10n, state.error!),
                      key: const Key('activation-error'),
                    ),
                  TextField(
                    key: const Key('activation-server'),
                    controller: _server,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: l10n.activationServerLabel,
                      hintText: l10n.pairingServerHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('activation-key'),
                    controller: _key,
                    decoration: InputDecoration(
                      labelText: l10n.activationKeyLabel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('activation-name'),
                    controller: _name,
                    decoration: InputDecoration(
                      labelText: l10n.activationNameLabel,
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('activation-submit'),
                    onPressed: state.busy
                        ? null
                        : () => unawaited(
                            context.read<ActivationCubit>().activate(
                              _server.text,
                              _key.text,
                              _name.text,
                            ),
                          ),
                    child: state.busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.activationSubmit),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}
