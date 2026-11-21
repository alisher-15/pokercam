import 'package:flutter/material.dart';

import '../brand.dart';
import '../contracts/contracts.dart';

/// What the app knows of its brand now: the build's (BuildBrand), then the server's (GET /brand).
class BrandLook {
  const BrandLook({required this.colors, this.logoUrl});

  BrandLook.ofBuild() : colors = BuildBrand.colors, logoUrl = null;

  /// The server's brand; its logo_url may be a path on the backend ([apiUrl]).
  BrandLook.ofServer(BrandResponse brand, String apiUrl)
    : colors = brand.colors,
      logoUrl = brand.logoUrl == null
          ? null
          : Uri.parse(apiUrl).resolve(brand.logoUrl!);

  final BrandColors colors;

  /// The server's logo, absolute; null means the build's.
  final Uri? logoUrl;
}

/// The brand's logo: the server's when it has one, else the one built into the app; nothing if neither loads.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.logoUrl, this.height = 56});

  final Uri? logoUrl;
  final double height;

  @override
  Widget build(BuildContext context) {
    Widget none(BuildContext context, Object error, StackTrace? stack) =>
        SizedBox(height: height);
    final url = logoUrl;
    return SizedBox(
      key: const Key('brand-logo'),
      height: height,
      child: url != null
          ? Image.network(url.toString(), height: height, errorBuilder: none)
          : Image.asset(
              BuildBrand.logoAsset,
              height: height,
              errorBuilder: none,
            ),
    );
  }
}
