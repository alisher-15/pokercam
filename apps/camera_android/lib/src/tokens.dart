import 'package:shared/shared.dart';

/// Access tokens for the phone's refresh token (SPEC 9.1: 12 h, refreshed hourly). A 401 means the phone
/// was unpaired or replaced: the caller goes back to pairing.
class TokenSource {
  TokenSource(
    this._api,
    this._refreshToken, {
    this.maxAge = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ApiClient _api;
  final String _refreshToken;
  final Duration maxAge;
  final DateTime Function() _now;
  TokenResponse? _token;
  DateTime? _at;

  Future<TokenResponse> get() async {
    final token = _token;
    final at = _at;
    if (token != null && at != null && _now().difference(at) < maxAge) {
      return token;
    }
    final fresh = await _api.token(_refreshToken);
    _token = fresh;
    _at = _now();
    return fresh;
  }

  /// media-server refused the token (e.g. the key changed): the next get() asks the backend again.
  void invalidate() {
    _token = null;
    _at = null;
  }
}
