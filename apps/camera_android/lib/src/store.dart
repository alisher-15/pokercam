import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared/shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What pairing gave this phone (SPEC 9.2): the backend's address, the device refresh token and the table.
class Pairing {
  const Pairing({
    required this.apiUrl,
    required this.refreshToken,
    required this.deviceId,
    required this.tableId,
    required this.clientId,
  });

  final String apiUrl;
  final String refreshToken;
  final String deviceId;
  final String tableId;
  final String clientId;

  Map<String, dynamic> toJson() => {
    'api_url': apiUrl,
    'refresh_token': refreshToken,
    'device_id': deviceId,
    'table_id': tableId,
    'client_id': clientId,
  };

  factory Pairing.fromJson(Map<String, dynamic> json) => Pairing(
    apiUrl: json['api_url'] as String,
    refreshToken: json['refresh_token'] as String,
    deviceId: json['device_id'] as String,
    tableId: json['table_id'] as String,
    clientId: json['client_id'] as String,
  );
}

abstract interface class PairingStore {
  Future<Pairing?> load();
  Future<void> save(Pairing pairing);
  Future<void> clear();

  /// The last server address typed or scanned, to prefill the manual form.
  Future<String?> lastApiUrl();
}

/// The refresh token lives in the Android Keystore (flutter_secure_storage), never in plain preferences.
class SecurePairingStore implements PairingStore {
  SecurePairingStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'pairing';
  static const _apiKey = 'last_api_url';

  @override
  Future<Pairing?> load() async {
    final text = await _storage.read(key: _key);
    if (text == null) return null;
    try {
      return Pairing.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } on Object {
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(Pairing pairing) async {
    await _storage.write(key: _key, value: jsonEncode(pairing.toJson()));
    await _storage.write(key: _apiKey, value: pairing.apiUrl);
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);

  @override
  Future<String?> lastApiUrl() => _storage.read(key: _apiKey);
}

/// SPEC 6.2: the last value of each camera parameter survives reconnects and restarts.
abstract interface class SettingsStore {
  Future<Map<String, CameraControl>> load();
  Future<void> save(String param, CameraControl control);
  Future<void> clear();
}

class PreferencesSettingsStore implements SettingsStore {
  static const _key = 'camera_settings';

  @override
  Future<Map<String, CameraControl>> load() async {
    final text = (await SharedPreferences.getInstance()).getString(_key);
    if (text == null) return {};
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return {
        for (final e in json.entries)
          e.key: CameraControl.fromJson(e.value as Map<String, dynamic>),
      };
    } on Object {
      return {};
    }
  }

  @override
  Future<void> save(String param, CameraControl control) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await load();
    all[param] = control;
    await prefs.setString(
      _key,
      jsonEncode({
        for (final e in all.entries) e.key: withoutNulls(e.value.toJson()),
      }),
    );
  }

  @override
  Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_key);
}
