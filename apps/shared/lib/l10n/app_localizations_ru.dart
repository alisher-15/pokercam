// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get cameraAppTitle => 'Камера стола';

  @override
  String get viewerAppTitle => 'Просмотр стола';

  @override
  String get underConstruction => 'Этот экран ещё в разработке.';
}
