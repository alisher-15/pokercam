import 'package:flutter/material.dart';

import 'contracts/contracts.dart';

/// Parses a schema color (`#RRGGBB`) into an opaque [Color].
Color parseColor(String hex) {
  final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(hex);
  if (match == null) throw FormatException('expected #RRGGBB', hex);
  return Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
}

/// Dark theme of both apps, built from a brand's colors (brand.json or GET /api/v1/brand).
///
/// A brand's primary and secondary are usually dark (a logo's colors), and in a dark theme Material paints
/// text and text buttons in `primary`: unreadable on the dark background. So `primary` is a light tone of the
/// brand's hue (Material's own scheme from it), readable on the background, and the brand's own colors go
/// where they fill a surface: `primaryContainer` and `secondaryContainer`, with a readable text color on them.
ThemeData buildTheme(BrandColors colors) {
  final primary = parseColor(colors.primary);
  final secondary = parseColor(colors.secondary);
  final accent = parseColor(colors.accent);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.dark,
      ).copyWith(
        primaryContainer: primary,
        onPrimaryContainer: readableOn(primary),
        secondaryContainer: secondary,
        onSecondaryContainer: readableOn(secondary),
        tertiary: accent,
        onTertiary: readableOn(accent),
        surface: parseColor(colors.background),
      );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
  );
}

/// WCAG contrast ratio of two colors: 1 (same) to 21 (black on white); text wants 4.5 or more.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
}

/// Black or white, whichever reads better on [background].
Color readableOn(Color background) =>
    contrastRatio(Colors.white, background) >=
        contrastRatio(Colors.black, background)
    ? Colors.white
    : Colors.black;

/// Neutral colors: a build without a brand (BuildBrand.colors has the same defaults).
final neutralColors = BrandColors(
  primary: '#3F6E8C',
  secondary: '#2B3138',
  background: '#121417',
  accent: '#C9A227',
);
