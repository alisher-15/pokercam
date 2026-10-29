import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../contracts/contracts.dart';
import '../wire.dart';

/// A failed backend call: HTTP status and the `detail.code` of the error body (contracts/rest/error_response.json).
class ApiException implements Exception {
  const ApiException(this.status, this.code, [this.message = '']);

  /// 0 when the server could not be reached at all.
  final int status;
  final String code;
  final String message;

  bool get unreachable => status == 0;

  /// The refresh token or device is no longer valid (revoked, replaced, unknown): pair again.
  bool get unauthorized => status == 401;

  @override
  String toString() =>
      'ApiException($status, $code${message.isEmpty ? '' : ': $message'})';
}

/// The backend's public API (SPEC 5.2) as the apps call it.
class ApiClient {
  ApiClient(
    String baseUrl, {
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _http = client ?? http.Client();

  final String baseUrl;
  final Duration timeout;
  final http.Client _http;

  /// The camera's half of pairing (SPEC 9.2): the code from the PC's QR code for a device refresh token.
  Future<DevicePairResponse> pairDevice({
    required String code,
    required String model,
    required String androidId,
  }) async => DevicePairResponse.fromJson(
    await _call(
      'POST',
      '/device/pair',
      body: DevicePairRequest(
        code: code,
        model: model,
        androidId: androidId,
      ).toJson(),
    ),
  );

  /// An access token (12 h) and media-server's address for a refresh token; a viewer names its table.
  Future<TokenResponse> token(String refreshToken, {String? tableId}) async =>
      TokenResponse.fromJson(
        await _call(
          'POST',
          '/auth/token',
          body: TokenRequest(
            refreshToken: refreshToken,
            tableId: tableId,
          ).toJson(),
        ),
      );

  /// The client's license (SPEC 9.1: at start and hourly).
  Future<LicenseResponse> license(String accessToken) async =>
      LicenseResponse.fromJson(
        await _call('GET', '/license', accessToken: accessToken),
      );

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl/api/v1$path'));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = encodeWire(body);
    }
    if (accessToken != null) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(timeout),
      );
    } on TimeoutException {
      throw const ApiException(0, 'timeout');
    } on SocketException catch (e) {
      throw ApiException(0, 'unreachable', e.message);
    } on http.ClientException catch (e) {
      throw ApiException(0, 'unreachable', e.message);
    }
    final Object? json;
    try {
      json = response.body.isEmpty
          ? null
          : jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException(response.statusCode, 'bad_response');
    }
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        json is Map<String, dynamic>) {
      return json;
    }
    final detail = json is Map<String, dynamic> ? json['detail'] : null;
    if (detail is Map<String, dynamic>) {
      throw ApiException(
        response.statusCode,
        '${detail['code']}',
        '${detail['message'] ?? ''}',
      );
    }
    throw ApiException(response.statusCode, 'http_${response.statusCode}');
  }

  void close() => _http.close();
}
