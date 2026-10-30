import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared/shared.dart';

import '../app.dart';
import '../platform/camera2.dart';
import '../platform/device.dart';
import '../store.dart';
import 'pairing_screen.dart';
import 'preview.dart';

class PreflightState {
  const PreflightState({
    this.loading = true,
    this.permissions,
    this.camera,
    this.cameraError,
    this.h264,
    this.license,
    this.licenseError,
  });

  final bool loading;
  final Permissions? permissions;
  final CameraInfo? camera;
  final String? cameraError;

  /// The phone has a hardware H.264 encoder (SPEC 6.3; the DVR needs H.264).
  final bool? h264;
  final LicenseResponse? license;

  /// The backend's error code when the license could not be read (`license_expired`, `unreachable`, …).
  final String? licenseError;

  bool get licenseBlocked =>
      licenseError == 'license_expired' ||
      licenseError == 'license_suspended' ||
      licenseError == 'no_license' ||
      license?.status == LicenseStatus.EXPIRED ||
      license?.status == LicenseStatus.SUSPENDED;

  /// SPEC 6.1: the start button needs every required check green: the camera works and the club has access.
  bool get canStart =>
      !loading &&
      permissions?.camera == true &&
      camera != null &&
      !licenseBlocked;
}

/// Screen 2 of SPEC 6.1: opens the camera (the same stream goes on air) and checks what the table needs.
class PreflightCubit extends Cubit<PreflightState> {
  PreflightCubit(this.services, this.app, this.pairing)
    : super(const PreflightState());

  final Services services;
  final AppCubit app;
  final Pairing pairing;

  Future<void> check({bool ask = true}) async {
    emit(const PreflightState());
    var permissions = await services.device.permissions();
    if (ask && (!permissions.camera || !permissions.notifications)) {
      permissions = await services.device.requestPermissions();
    }
    CameraInfo? camera;
    String? cameraError;
    bool? h264;
    if (permissions.camera) {
      try {
        await scannerReleased.timeout(
          const Duration(seconds: 15),
          onTimeout: () {},
        );
        final trackId = await services.publisher.openCamera();
        camera = await services.camera.capabilities(trackId);
        h264 =
            (await services.camera.deviceInfo())['h264_hardware_encoder'] ==
            true;
      } on CameraControlError catch (e) {
        cameraError = e.code;
      } on Object catch (e) {
        cameraError = '$e';
      }
    }
    LicenseResponse? license;
    String? licenseError;
    final api = services.api(pairing.apiUrl);
    try {
      final token = await api.token(pairing.refreshToken);
      license = await api.license(token.accessToken);
    } on ApiException catch (e) {
      if (e.unauthorized) {
        api.close();
        await app.unpaired(replaced: true);
        return;
      }
      licenseError = e.unreachable ? 'unreachable' : e.code;
    } finally {
      api.close();
    }
    services.log.info('pre-flight check', {
      'camera_permission': permissions.camera,
      'capture_size': camera?.captureSize,
      'hardware_level': camera?.hardwareLevel,
      'camera_error': cameraError,
      'h264_hardware_encoder': h264,
      'license': license?.status.name,
      'license_error': licenseError,
    });
    if (isClosed) return;
    emit(
      PreflightState(
        loading: false,
        permissions: permissions,
        camera: camera,
        cameraError: cameraError,
        h264: h264,
        license: license,
        licenseError: licenseError,
      ),
    );
  }

  Future<void> fixPermissions() async {
    await services.device.requestPermissions();
    await check(ask: false);
  }

  Future<void> fixBattery() async {
    await services.device.requestBatteryExemption();
  }
}

class PreflightScreen extends StatelessWidget {
  const PreflightScreen({super.key, required this.pairing});

  final Pairing pairing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider(
      create: (context) => PreflightCubit(
        context.read<Services>(),
        context.read<AppCubit>(),
        pairing,
      )..check(),
      child: BlocBuilder<PreflightCubit, PreflightState>(
        builder: (context, state) {
          final cubit = context.read<PreflightCubit>();
          final services = context.read<Services>();
          return Scaffold(
            appBar: AppBar(
              title: Text(l10n.preflightTitle),
              actions: [
                IconButton(
                  key: const Key('preflight-recheck'),
                  tooltip: l10n.preflightRecheck,
                  onPressed: state.loading
                      ? null
                      : () => unawaited(cubit.check(ask: false)),
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<void>(
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      onTap: () => unawaited(_confirmUnpair(context)),
                      child: Text(l10n.unpair),
                    ),
                  ],
                ),
              ],
            ),
            body: state.loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    key: const Key('preflight-screen'),
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (services.publisher.stream != null)
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Preview(stream: services.publisher.stream!),
                        ),
                      _Section(l10n.preflightCamera),
                      if (state.cameraError != null)
                        _Check(
                          ok: false,
                          title: l10n.preflightCameraError(state.cameraError!),
                          required: true,
                          l10n: l10n,
                        ),
                      if (state.camera != null)
                        ..._params(l10n, state.camera!.params),
                      _Section(l10n.preflightVideo),
                      _Check(
                        ok: state.camera?.isFullHd ?? false,
                        title: l10n.preflightResolution,
                        detail: state.camera == null
                            ? null
                            : l10n.preflightResolutionActual(
                                state.camera!.captureSize.replaceAll('x', '×'),
                              ),
                        l10n: l10n,
                      ),
                      _Check(
                        ok: state.h264 ?? false,
                        title: l10n.preflightCodec,
                        detail: state.h264 == false
                            ? l10n.preflightCodecMissing
                            : null,
                        l10n: l10n,
                      ),
                      _Section(l10n.preflightSystem),
                      _Check(
                        ok: state.permissions?.camera ?? false,
                        title: l10n.preflightCameraPermission,
                        required: true,
                        l10n: l10n,
                        fix: () => unawaited(cubit.fixPermissions()),
                      ),
                      _Check(
                        ok: state.permissions?.notifications ?? false,
                        title: l10n.preflightNotifications,
                        l10n: l10n,
                        fix: () => unawaited(cubit.fixPermissions()),
                      ),
                      _Check(
                        ok: state.permissions?.batteryUnrestricted ?? false,
                        title: l10n.preflightBattery,
                        l10n: l10n,
                        fix: () => unawaited(cubit.fixBattery()),
                      ),
                      _Check(
                        ok: state.license != null && !state.licenseBlocked,
                        title: l10n.preflightLicense,
                        detail: _license(context, l10n, state),
                        required: true,
                        l10n: l10n,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const Key('preflight-start'),
                        onPressed: state.canStart
                            ? context.read<AppCubit>().startBroadcast
                            : null,
                        icon: const Icon(Icons.videocam),
                        label: Text(l10n.preflightStart),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  static Iterable<Widget> _params(
    AppLocalizations l10n,
    CameraParamCapabilities params,
  ) sync* {
    final names = {
      l10n.paramFocus: params.focus,
      l10n.paramIso: params.iso,
      l10n.paramExposure: params.exposure,
      l10n.paramBrightness: params.brightness,
      l10n.paramContrast: params.contrast,
      l10n.paramWhiteBalance: params.whiteBalance,
      l10n.paramZoom: params.zoom,
    };
    for (final MapEntry(key: name, value: capability) in names.entries) {
      yield _Check(
        ok: capability.supported,
        title: name,
        detail: capability.supported ? l10n.supported : l10n.notSupported,
        l10n: l10n,
      );
    }
  }

  static String? _license(
    BuildContext context,
    AppLocalizations l10n,
    PreflightState state,
  ) {
    final date = DateFormat.yMd(
      Localizations.localeOf(context).toLanguageTag(),
    );
    final license = state.license;
    if (state.licenseBlocked) return l10n.licenseBlocked;
    if (license == null) {
      return state.licenseError == 'unreachable'
          ? l10n.preflightLicenseUnknown
          : state.licenseError;
    }
    return license.status == LicenseStatus.GRACE
        ? l10n.licenseGrace(date.format(license.graceUntil.toLocal()))
        : l10n.licenseActive(date.format(license.paidUntil.toLocal()));
  }

  static Future<void> _confirmUnpair(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final app = context.read<AppCubit>();
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.unpairConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (yes == true) await app.unpaired();
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _Check extends StatelessWidget {
  const _Check({
    required this.ok,
    required this.title,
    required this.l10n,
    this.detail,
    this.required = false,
    this.fix,
  });

  final bool ok;
  final String title;
  final String? detail;
  final bool required;
  final VoidCallback? fix;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle = [
      ?detail,
      if (required && !ok) l10n.preflightRequired,
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: Icon(
        ok
            ? Icons.check_circle
            : (required ? Icons.cancel : Icons.warning_amber),
        color: ok ? Colors.green : (required ? colors.error : Colors.orange),
      ),
      title: Text(title),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: !ok && fix != null
          ? TextButton(onPressed: fix, child: Text(l10n.preflightFix))
          : null,
    );
  }
}
