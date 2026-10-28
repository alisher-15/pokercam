import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  test('parseColor reads #RRGGBB as an opaque color', () {
    expect(parseColor('#0F5132'), const Color(0xFF0F5132));
    expect(() => parseColor('0F5132'), throwsFormatException);
    expect(() => parseColor('#0F513'), throwsFormatException);
  });

  test('buildTheme uses the brand colors', () {
    final theme = buildTheme(
      BrandColors(
        primary: '#0F5132',
        secondary: '#1B1F24',
        background: '#101418',
        accent: '#E0B341',
      ),
    );
    expect(theme.colorScheme.primary, const Color(0xFF0F5132));
    expect(theme.colorScheme.secondary, const Color(0xFF1B1F24));
    expect(theme.colorScheme.surface, const Color(0xFF101418));
    expect(theme.colorScheme.tertiary, const Color(0xFFE0B341));
    expect(theme.brightness, Brightness.dark);
  });
}
