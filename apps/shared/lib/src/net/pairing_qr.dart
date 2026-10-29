import 'dart:convert';

/// What a pairing QR code carries (backend: POST /tables/{id}/pairing-code, `qr_payload`):
/// `{"v":1,"api":"https://…","code":"123456"}` — the server address and a one-time code.
class PairingQr {
  const PairingQr({required this.apiUrl, required this.code});

  final String apiUrl;
  final String code;

  static final _code = RegExp(r'^[0-9]{6}$');

  static bool isCode(String text) => _code.hasMatch(text);

  /// The QR text, or null when it is not a PokerCam pairing code.
  static PairingQr? parse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic> || json['v'] != 1) return null;
      final api = json['api'];
      final code = json['code'];
      if (api is! String || code is! String || !isCode(code)) return null;
      final uri = Uri.tryParse(api);
      if (uri == null ||
          !(uri.isScheme('http') || uri.isScheme('https')) ||
          uri.host.isEmpty) {
        return null;
      }
      return PairingQr(apiUrl: normalizeApiUrl(api), code: code);
    } on FormatException {
      return null;
    }
  }

  /// A server address as typed by hand: scheme added if missing, no trailing slash.
  static String normalizeApiUrl(String text) {
    var url = text.trim();
    if (!url.contains('://')) url = 'http://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
