import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

Set<String> keys(String locale) {
  final arb = jsonDecode(
    File('lib/l10n/app_$locale.arb').readAsStringSync(),
  ) as Map<String, dynamic>;
  return arb.keys.where((k) => !k.startsWith('@')).toSet();
}

void main() {
  test('Russian and English have the same strings', () {
    expect(keys('ru'), keys('en'));
  });

  test('both languages are supported', () {
    expect(
      AppLocalizations.supportedLocales,
      containsAll([const Locale('en'), const Locale('ru')]),
    );
  });

  test('strings resolve in Russian', () async {
    final ru = await AppLocalizations.delegate.load(const Locale('ru'));
    expect(ru.cameraAppTitle, 'Камера стола');
  });
}
