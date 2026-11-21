import 'dart:convert';

import 'contracts/contracts.dart';

/// The brand this build was made for (SPEC 10.1). `make build BRAND=<brand>` (tools/brand/brand.ts) passes
/// `branding/<brand>/brand.json` as `--dart-define-from-file`; a build without it (tests, `flutter run`) gets
/// neutral values. The server's brand (GET /brand) refines the colors and the logo at run time.
abstract final class BuildBrand {
  /// Empty without a brand: the apps then show their neutral titles.
  static const appName = String.fromEnvironment('BRAND_APP_NAME');

  static final colors = BrandColors(
    primary: const String.fromEnvironment(
      'BRAND_COLOR_PRIMARY',
      defaultValue: '#3F6E8C',
    ),
    secondary: const String.fromEnvironment(
      'BRAND_COLOR_SECONDARY',
      defaultValue: '#2B3138',
    ),
    background: const String.fromEnvironment(
      'BRAND_COLOR_BACKGROUND',
      defaultValue: '#121417',
    ),
    accent: const String.fromEnvironment(
      'BRAND_COLOR_ACCENT',
      defaultValue: '#C9A227',
    ),
  );

  /// The brand's logo, copied into this package by tools/brand/brand.ts (the default brand's is committed).
  static const logoAsset = 'packages/shared/assets/brand/logo.png';

  /// brand.json's seller_contacts: shown when the server has given none (SPEC 8.4).
  static final SellerContacts? sellerContacts = _contacts(
    const String.fromEnvironment('BRAND_SELLER_CONTACTS'),
  );

  static SellerContacts? _contacts(String json) {
    if (json.isEmpty) return null;
    try {
      return SellerContacts.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }
}
