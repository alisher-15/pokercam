import 'package:viewer_windows/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the English title', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const ViewerApp());
    expect(find.text('Table viewer'), findsOneWidget);
  });

  testWidgets('shows the Russian title', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const ViewerApp());
    expect(find.text('Просмотр стола'), findsOneWidget);
  });
}
