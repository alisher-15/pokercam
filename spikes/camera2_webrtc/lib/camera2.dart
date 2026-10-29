import 'dart:convert';

import 'package:flutter/services.dart';

/// Dart side of the native Camera2Control (android/.../Camera2Control.kt).
class Camera2 {
  static const _channel = MethodChannel('spike/camera2');

  Future<Map<String, dynamic>> deviceInfo() async =>
      _plain(await _channel.invokeMethod('deviceInfo'));

  Future<Map<String, dynamic>> capabilities(String trackId) async =>
      _plain(await _channel.invokeMethod('capabilities', {'trackId': trackId}));

  /// Applies one parameter; returns the setting actually requested (value clamped to the range).
  Future<Map<String, dynamic>> set(
    String trackId,
    String param,
    String mode, {
    double? value,
    String? preset,
  }) async => _plain(
    await _channel.invokeMethod('set', {
      'trackId': trackId,
      'param': param,
      'mode': mode,
      'value': value,
      'preset': preset,
    }),
  );

  Future<void> reset(String trackId) =>
      _channel.invokeMethod('reset', {'trackId': trackId});

  /// The camera's latest reported values and, per requested parameter, how long it took to apply.
  Future<Map<String, dynamic>> state() async =>
      _plain(await _channel.invokeMethod('state'));

  /// Platform maps arrive as `Map<Object?, Object?>`; a JSON round trip makes them plain Dart maps.
  static Map<String, dynamic> _plain(Object? value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}
