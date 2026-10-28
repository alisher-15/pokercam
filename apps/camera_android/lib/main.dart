import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

void main() => runApp(const CameraApp());

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    onGenerateTitle: (context) => AppLocalizations.of(context).cameraAppTitle,
    theme: buildTheme(neutralColors),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const _HomeScreen(),
  );
}

/// Placeholder until the real screens arrive (SPEC section 12).
class _HomeScreen extends StatelessWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cameraAppTitle)),
      body: Center(child: Text(l10n.underConstruction)),
    );
  }
}
