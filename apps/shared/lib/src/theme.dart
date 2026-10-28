import 'package:flutter/material.dart';

import 'contracts/contracts.dart';

/// Parses a schema color (`#RRGGBB`) into an opaque [Color].
Color parseColor(String hex) {
  final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(hex);
  if (match == null) throw FormatException('expected #RRGGBB', hex);
  return Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
}

/// Dark theme of both apps, built from a brand's colors (brand.json or GET /api/v1/brand).
ThemeData buildTheme(BrandColors colors) {
  final primary = parseColor(colors.primary);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: primary,
        secondary: parseColor(colors.secondary),
        tertiary: parseColor(colors.accent),
        surface: parseColor(colors.background),
      );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
  );
}

/// Neutral colors used until the build injects a brand (stage 8).
final neutralColors = BrandColors(
  primary: '#3F6E8C',
  secondary: '#2B3138',
  background: '#121417',
  accent: '#C9A227',
);
