import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

/// Battery, temperature, thermal status and network right now (device.telemetry, SPEC 6.4).
class DeviceSnapshot {
  const DeviceSnapshot({
    required this.batteryPct,
    required this.charging,
    required this.tempC,
    required this.thermal,
    required this.network,
  });

  final int batteryPct;
  final bool charging;

  /// Battery temperature.
  final double tempC;
  final ThermalStatus thermal;
  final NetworkInfo network;

  bool get online => network.type != NetworkType.NONE;

  factory DeviceSnapshot.fromJson(Map<String, dynamic> json) => DeviceSnapshot(
    batteryPct: (json['battery_pct'] as num).toInt(),
    charging: json['charging'] == true,
    tempC: (json['temp_c'] as num).toDouble(),
    thermal:
        thermalStatusValues.map[json['thermal_status']] ?? ThermalStatus.NONE,
    network: NetworkInfo.fromJson(json['network'] as Map<String, dynamic>),
  );
}

/// Runtime permissions and the battery exemption the pre-flight check shows (SPEC 6.1, 6.3).
class Permissions {
  const Permissions({
    required this.camera,
    required this.notifications,
    required this.batteryUnrestricted,
  });

  final bool camera;
  final bool notifications;
  final bool batteryUnrestricted;

  factory Permissions.fromJson(Map<String, dynamic> json) => Permissions(
    camera: json['camera'] == true,
    notifications: json['notifications'] == true,
    batteryUnrestricted: json['battery_unrestricted'] == true,
  );
}

/// The phone around the camera: identity for pairing, status for telemetry, the foreground service.
abstract interface class DeviceApi {
  Future<DeviceSnapshot> snapshot();

  /// `android_id` (stored hashed by the backend) and a readable model name, for POST /device/pair.
  Future<({String androidId, String model})> identity();
  Future<Permissions> permissions();
  Future<Permissions> requestPermissions();
  Future<void> requestBatteryExemption();

  /// SPEC 6.3: a foreground service with a wake lock while on air; texts are the localized notification.
  Future<void> startService({
    required String title,
    required String text,
    required String channel,
  });
  Future<void> stopService();
  Future<void> keepScreenOn(bool on);
}

class DeviceChannel implements DeviceApi {
  static const _channel = MethodChannel('pokercam/device');

  @override
  Future<DeviceSnapshot> snapshot() async =>
      DeviceSnapshot.fromJson(_plain(await _channel.invokeMethod('snapshot')));

  @override
  Future<({String androidId, String model})> identity() async {
    final json = _plain(await _channel.invokeMethod('identity'));
    return (androidId: '${json['android_id']}', model: '${json['model']}');
  }

  @override
  Future<Permissions> permissions() async =>
      Permissions.fromJson(_plain(await _channel.invokeMethod('permissions')));

  @override
  Future<Permissions> requestPermissions() async => Permissions.fromJson(
    _plain(await _channel.invokeMethod('requestPermissions')),
  );

  @override
  Future<void> requestBatteryExemption() =>
      _channel.invokeMethod('requestBatteryExemption');

  @override
  Future<void> startService({
    required String title,
    required String text,
    required String channel,
  }) => _channel.invokeMethod('startService', {
    'title': title,
    'text': text,
    'channel': channel,
  });

  @override
  Future<void> stopService() => _channel.invokeMethod('stopService');

  @override
  Future<void> keepScreenOn(bool on) =>
      _channel.invokeMethod('keepScreenOn', {'on': on});

  static Map<String, dynamic> _plain(Object? value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}
