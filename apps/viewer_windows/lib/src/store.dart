import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared/shared.dart';

/// What activation gave this PC (SPEC 8.1): the backend's address and the PC's refresh token.
class Connection {
  const Connection({
    required this.apiUrl,
    required this.refreshToken,
    required this.viewerId,
    required this.clientId,
  });

  final String apiUrl;
  final String refreshToken;
  final String viewerId;
  final String clientId;

  Map<String, dynamic> toJson() => {
    'api_url': apiUrl,
    'refresh_token': refreshToken,
    'viewer_id': viewerId,
    'client_id': clientId,
  };

  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
    apiUrl: json['api_url'] as String,
    refreshToken: json['refresh_token'] as String,
    viewerId: json['viewer_id'] as String,
    clientId: json['client_id'] as String,
  );
}

abstract interface class ConnectionStore {
  Future<Connection?> load();
  Future<void> save(Connection connection);
  Future<void> clear();

  /// The last server address typed, to prefill activation after a sign-out.
  Future<String?> lastApiUrl();

  /// This computer's id for activation: the same after a reinstall, so it stays one PC in the admin panel.
  Future<String> machineId();
}

/// The Windows Credential Manager (flutter_secure_storage): the refresh token is a credential.
class SecureConnectionStore implements ConnectionStore {
  SecureConnectionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'connection';
  static const _apiKey = 'last_api_url';
  static const _machineKey = 'machine_id';

  @override
  Future<Connection?> load() async {
    final text = await _storage.read(key: _key);
    if (text == null) return null;
    try {
      return Connection.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } on Object {
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(Connection connection) async {
    await _storage.write(key: _key, value: jsonEncode(connection.toJson()));
    await _storage.write(key: _apiKey, value: connection.apiUrl);
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);

  @override
  Future<String?> lastApiUrl() => _storage.read(key: _apiKey);

  @override
  Future<String> machineId() async {
    final saved = await _storage.read(key: _machineKey);
    if (saved != null) return saved;
    final id = await windowsMachineGuid() ?? newUuid();
    await _storage.write(key: _machineKey, value: id);
    return id;
  }
}

/// Windows' own id of this installation (HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid), read with reg.exe.
Future<String?> windowsMachineGuid() async {
  if (!Platform.isWindows) return null;
  try {
    final result = await Process.run('reg', [
      'query',
      r'HKLM\SOFTWARE\Microsoft\Cryptography',
      '/v',
      'MachineGuid',
    ]);
    return parseMachineGuid('${result.stdout}');
  } on Object {
    return null;
  }
}

/// The value of `MachineGuid    REG_SZ    <guid>` in reg.exe's output.
String? parseMachineGuid(String output) =>
    RegExp(r'MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]{36})')
        .firstMatch(output)
        ?.group(1)
        ?.toLowerCase();
