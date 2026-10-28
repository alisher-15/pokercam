import 'package:camera_android/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the English title', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const CameraApp());
    expect(find.text('Table camera'), findsOneWidget);
  });

  testWidgets('shows the Russian title', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const CameraApp());
    expect(find.text('Камера стола'), findsOneWidget);
  });
}
