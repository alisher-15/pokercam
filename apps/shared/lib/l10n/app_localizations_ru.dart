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

  @override
  String get pairingTitle => 'Привязка к столу';

  @override
  String get pairingScanHint =>
      'Наведите камеру на QR-код из «Привязать телефон» в Windows-клиенте.';

  @override
  String get pairingManual => 'Ввести код вручную';

  @override
  String get pairingScan => 'Сканировать QR-код';

  @override
  String get pairingServerLabel => 'Адрес сервера';

  @override
  String get pairingCodeLabel => 'Код из 6 цифр';

  @override
  String get pairingSubmit => 'Привязать';

  @override
  String get pairingInProgress => 'Привязываем…';

  @override
  String get pairingErrorCode =>
      'Код неверный или истёк. Запросите новый на ПК.';

  @override
  String get pairingErrorTooMany =>
      'Слишком много попыток. Подождите минуту и попробуйте снова.';

  @override
  String get pairingErrorUnreachable =>
      'Сервер не отвечает. Проверьте адрес и сеть.';

  @override
  String get pairingErrorLicense =>
      'Доступ клуба закончился. Обратитесь к администратору.';

  @override
  String pairingErrorOther(String code) {
    return 'Не удалось привязать ($code).';
  }

  @override
  String get pairingQrNotOurs => 'Это не QR-код привязки PokerCam.';

  @override
  String get pairingReplaced =>
      'Этот телефон заменён другим или отвязан. Привяжите его снова.';

  @override
  String get preflightTitle => 'Проверка перед трансляцией';

  @override
  String get preflightCamera => 'Параметры камеры';

  @override
  String get preflightVideo => 'Видео';

  @override
  String get preflightSystem => 'Телефон';

  @override
  String get paramFocus => 'Фокус';

  @override
  String get paramIso => 'ISO';

  @override
  String get paramExposure => 'Выдержка';

  @override
  String get paramBrightness => 'Яркость';

  @override
  String get paramContrast => 'Контраст';

  @override
  String get paramWhiteBalance => 'Баланс белого';

  @override
  String get paramZoom => 'Зум';

  @override
  String get supported => 'поддерживается';

  @override
  String get notSupported => 'не поддерживается';

  @override
  String get preflightResolution => 'Разрешение 1920×1080';

  @override
  String preflightResolutionActual(String size) {
    return 'камера даёт $size';
  }

  @override
  String get preflightCodec => 'Кодер H.264';

  @override
  String get preflightCodecMissing =>
      'нет H.264: прямой эфир работает, перемотка — нет';

  @override
  String get preflightCameraPermission => 'Доступ к камере';

  @override
  String get preflightNotifications => 'Уведомления (для работы в фоне)';

  @override
  String get preflightBattery => 'Без ограничений батареи';

  @override
  String get preflightLicense => 'Доступ';

  @override
  String licenseActive(String date) {
    return 'активен до $date';
  }

  @override
  String licenseGrace(String date) {
    return 'оплата просрочена: отключится $date';
  }

  @override
  String get licenseBlocked => 'заблокирован';

  @override
  String get preflightRequired => 'обязательно';

  @override
  String get preflightFix => 'Разрешить';

  @override
  String get preflightRecheck => 'Проверить снова';

  @override
  String get preflightStart => 'Начать трансляцию';

  @override
  String get unpair => 'Отвязать телефон';

  @override
  String get unpairConfirm =>
      'Телефон перестанет быть камерой стола. Продолжить?';

  @override
  String get cancel => 'Отмена';

  @override
  String get confirm => 'Продолжить';

  @override
  String get liveBadge => 'LIVE';

  @override
  String get statusConnecting => 'Подключение…';

  @override
  String get statusReconnecting => 'Переподключение…';

  @override
  String statsBitrate(int kbps) {
    return '$kbps кбит/с';
  }

  @override
  String statsFps(int fps) {
    return '$fps к/с';
  }

  @override
  String statsBattery(int pct) {
    return '$pct %';
  }

  @override
  String statsTemperature(String temp) {
    return '$temp °C';
  }

  @override
  String get networkWifi => 'Wi-Fi';

  @override
  String get networkCellular => 'Мобильная сеть';

  @override
  String get networkEthernet => 'Ethernet';

  @override
  String get networkNone => 'Нет сети';

  @override
  String get bannerNoConnection => 'Нет связи с сервером. Переподключение…';

  @override
  String get bannerLicenseBlocked =>
      'Доступ клуба заблокирован: трансляция остановлена.';

  @override
  String bannerLicenseGrace(String date) {
    return 'Оплата просрочена: доступ отключится $date.';
  }

  @override
  String get stopStreaming => 'Остановить';

  @override
  String get alertOverheating =>
      'Телефон-камера перегревается: качество видео снижено.';

  @override
  String get alertOverheatingCritical =>
      'Телефон-камера сильно перегрет: качество видео сильно снижено.';

  @override
  String get alertCooledDown =>
      'Телефон-камера остыл: качество видео восстановлено.';

  @override
  String get alertLowBattery =>
      'Заряд телефона-камеры ниже 15 %. Подключите зарядку.';

  @override
  String get alertBatteryCritical =>
      'Заряд телефона-камеры ниже 5 %: трансляция скоро прервётся.';

  @override
  String get pairingCameraDenied =>
      'Нет доступа к камере — введите код вручную.';

  @override
  String get pairingServerHint => 'https://cam.club.kz';

  @override
  String get serviceChannel => 'Трансляция';

  @override
  String get serviceTitle => 'Камера стола в эфире';

  @override
  String get serviceText =>
      'Идёт трансляция на сервер. Не закрывайте приложение.';

  @override
  String preflightCameraError(String error) {
    return 'Камера не открылась: $error';
  }

  @override
  String get preflightLicenseUnknown => 'не проверить: нет связи с сервером';
}
