import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

/// A setting the camera refused; [code] is a contracts CameraErrorCode (`unsupported_param`, …).
class CameraControlError implements Exception {
  const CameraControlError(this.code, [this.message = '']);

  final String code;
  final String message;

  @override
  String toString() => 'CameraControlError($code: $message)';
}

/// What the camera reports about itself (SPEC 6.1 pre-flight check and `camera.capabilities`).
class CameraInfo {
  const CameraInfo({
    required this.params,
    required this.hardwareLevel,
    required this.captureSize,
    required this.fpsRange,
  });

  final CameraParamCapabilities params;
  final String hardwareLevel;

  /// e.g. "1920x1080": what the capturer really opened.
  final String captureSize;
  final String fpsRange;

  bool get isFullHd => captureSize == '1920x1080';

  factory CameraInfo.fromJson(Map<String, dynamic> json) => CameraInfo(
    params: CameraParamCapabilities.fromJson(
      json['params'] as Map<String, dynamic>,
    ),
    hardwareLevel: '${json['hardware_level']}',
    captureSize: '${json['capture_size']}',
    fpsRange: '${json['fps_range']}',
  );
}

/// A setting applied: [applied] is what the camera was asked for (value clamped to its range); [confirmed]
/// when the camera reported it in a CaptureResult, [afterMs] later (SPEC 6.5: ≤ 1 s).
class CameraSetResult {
  const CameraSetResult(this.applied, {required this.confirmed, this.afterMs});

  final CameraControl applied;
  final bool confirmed;
  final int? afterMs;
}

/// The camera2_control plugin (SPEC 6.2): manual settings on the camera session flutter_webrtc opened.
abstract interface class CameraControlApi {
  Future<Map<String, dynamic>> deviceInfo();
  Future<CameraInfo> capabilities(String trackId);
  Future<CameraSetResult> set(
    String trackId,
    CameraParam param,
    CameraControl control,
  );

  /// Restores saved settings at once; returns those the camera took.
  Future<Map<String, CameraControl>> apply(
    String trackId,
    Map<String, CameraControl> settings,
  );

  /// The camera was reopened: settings are applied to the new session again by the app.
  Future<void> forget();
}

class Camera2Channel implements CameraControlApi {
  static const _channel = MethodChannel('pokercam/camera2');

  @override
  Future<Map<String, dynamic>> deviceInfo() async =>
      _plain(await _invoke('deviceInfo'));

  @override
  Future<CameraInfo> capabilities(String trackId) async => CameraInfo.fromJson(
    _plain(await _invoke('capabilities', {'trackId': trackId})),
  );

  @override
  Future<CameraSetResult> set(
    String trackId,
    CameraParam param,
    CameraControl control,
  ) async {
    final json = withoutNulls(control.toJson());
    final answer = _plain(
      await _invoke('set', {
        'trackId': trackId,
        'param': cameraParamValues.reverse[param],
        'mode': json['mode'],
        'value': json['value'],
        'preset': json['preset'],
      }),
    );
    return CameraSetResult(
      CameraControl.fromJson(answer['applied'] as Map<String, dynamic>),
      confirmed: answer['confirmed'] == true,
      afterMs: (answer['after_ms'] as num?)?.toInt(),
    );
  }

  @override
  Future<Map<String, CameraControl>> apply(
    String trackId,
    Map<String, CameraControl> settings,
  ) async {
    final applied = _plain(
      await _invoke('apply', {
        'trackId': trackId,
        'settings': {
          for (final e in settings.entries)
            e.key: withoutNulls(e.value.toJson()),
        },
      }),
    );
    return {
      for (final e in applied.entries)
        e.key: CameraControl.fromJson(e.value as Map<String, dynamic>),
    };
  }

  @override
  Future<void> forget() => _invoke('forget');

  static Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (e) {
      throw CameraControlError(e.code, e.message ?? '');
    }
  }

  /// Platform maps arrive as `Map<Object?, Object?>`; a JSON round trip makes them plain Dart maps.
  static Map<String, dynamic> _plain(Object? value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}
