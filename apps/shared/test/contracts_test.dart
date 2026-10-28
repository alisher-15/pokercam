import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

import 'contract_models.dart';

final contracts = Directory('../../contracts');

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File('${contracts.path}/$path').readAsStringSync())
        as Map<String, dynamic>;

/// Dates come back as `2026-10-28T11:05:00.000Z` for `2026-10-28T11:05:00Z`: compare instants, not text.
Object? normalize(Object? value) => switch (value) {
  Map<String, dynamic> map => {
    for (final e in map.entries) e.key: normalize(e.value),
  },
  List<dynamic> list => list.map(normalize).toList(),
  String s when RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(s) => DateTime.parse(
    s,
  ).toUtc(),
  _ => value,
};

void main() {
  final examplesDir = Directory('${contracts.path}/examples/');
  final exampleFiles =
      examplesDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.substring(examplesDir.path.length))
          .toList()
        ..sort();

  test('every schema has a generated class', () {
    expect(contractModels.keys.toList()..sort(), exampleFiles);
  });

  group('examples survive decoding and encoding', () {
    for (final MapEntry(key: rel, value: roundTrip) in contractModels.entries) {
      test(rel, () {
        final example = readJson('examples/$rel');
        final encoded = withoutNulls(roundTrip(example));
        expect(
          const DeepCollectionEquality().equals(
            normalize(encoded),
            normalize(example),
          ),
          isTrue,
          reason: 'got ${jsonEncode(encoded)}',
        );
      });
    }
  });

  group('decodeMessage picks the class by type', () {
    for (final rel in exampleFiles.where(
      (r) => r.startsWith('ws/') && r != 'ws/envelope.json',
    )) {
      test(rel, () {
        final message = decodeMessage(readJson('examples/$rel'));
        expect(message.runtimeType.toString(), readJson(rel)['title']);
      });
    }
  });

  test('decodeMessage returns null for an unknown type', () {
    final json = readJson('examples/ws/control/camera.set.json')
      ..['type'] = 'camera.reboot';
    expect(decodeMessage(json), isNull);
  });
}
