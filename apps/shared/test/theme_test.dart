import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  test('parseColor reads #RRGGBB as an opaque color', () {
    expect(parseColor('#0F5132'), const Color(0xFF0F5132));
    expect(() => parseColor('0F5132'), throwsFormatException);
    expect(() => parseColor('#0F513'), throwsFormatException);
  });

  final brands = {
    'default': BrandColors(
      primary: '#0F5132',
      secondary: '#1B1F24',
      background: '#101418',
      accent: '#E0B341',
    ),
    'demo': BrandColors(
      primary: '#11496B',
      secondary: '#1E2A33',
      background: '#0B141A',
      accent: '#F2A541',
    ),
    'neutral': neutralColors,
  };

  test('buildTheme puts the brand colors where they fill a surface', () {
    final theme = buildTheme(brands['default']!);
    expect(theme.colorScheme.primaryContainer, const Color(0xFF0F5132));
    expect(theme.colorScheme.secondaryContainer, const Color(0xFF1B1F24));
    expect(theme.colorScheme.surface, const Color(0xFF101418));
    expect(theme.colorScheme.tertiary, const Color(0xFFE0B341));
    expect(theme.brightness, Brightness.dark);
    // primary keeps the brand's hue.
    final hue = HSLColor.fromColor(theme.colorScheme.primary).hue;
    expect(
      (hue - HSLColor.fromColor(const Color(0xFF0F5132)).hue).abs(),
      lessThan(25),
    );
  });

  for (final MapEntry(key: name, value: colors) in brands.entries) {
    test('$name: text and buttons are readable (contrast 4.5 or more)', () {
      final s = buildTheme(colors).colorScheme;
      for (final (what, fg, bg) in [
        ('primary text on the background', s.primary, s.surface),
        ('a filled button', s.onPrimary, s.primary),
        ('text on the brand color', s.onPrimaryContainer, s.primaryContainer),
        (
          'text on the secondary color',
          s.onSecondaryContainer,
          s.secondaryContainer,
        ),
        ('text on the accent', s.onTertiary, s.tertiary),
        ('text on the background', s.onSurface, s.surface),
      ]) {
        expect(contrastRatio(fg, bg), greaterThanOrEqualTo(4.5), reason: what);
      }
    });
  }

  test('contrastRatio: black on white is 21, a color on itself 1', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrastRatio(Colors.red, Colors.red), 1);
    expect(readableOn(const Color(0xFF0F5132)), Colors.white);
    expect(readableOn(const Color(0xFFE0B341)), Colors.black);
  });
}
