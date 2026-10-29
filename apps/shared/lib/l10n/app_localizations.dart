import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// Title of the camera app (Android phone above the table).
  ///
  /// In en, this message translates to:
  /// **'Table camera'**
  String get cameraAppTitle;

  /// Title of the Windows viewer app.
  ///
  /// In en, this message translates to:
  /// **'Table viewer'**
  String get viewerAppTitle;

  /// Placeholder until the app's screens are built (stages 5-7).
  ///
  /// In en, this message translates to:
  /// **'This screen is under construction.'**
  String get underConstruction;

  /// Pairing screen title (SPEC 6.1).
  ///
  /// In en, this message translates to:
  /// **'Pair with a table'**
  String get pairingTitle;

  /// Hint above the QR scanner.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the QR code from “Pair a phone” in the Windows app.'**
  String get pairingScanHint;

  /// Button that opens the manual pairing form.
  ///
  /// In en, this message translates to:
  /// **'Enter the code'**
  String get pairingManual;

  /// Button back to the QR scanner.
  ///
  /// In en, this message translates to:
  /// **'Scan the QR code'**
  String get pairingScan;

  /// Field: backend address, e.g. https://cam.club.kz.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get pairingServerLabel;

  /// Field: the pairing code shown on the PC.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get pairingCodeLabel;

  /// Button that pairs with the typed code.
  ///
  /// In en, this message translates to:
  /// **'Pair'**
  String get pairingSubmit;

  /// Shown while POST /device/pair runs.
  ///
  /// In en, this message translates to:
  /// **'Pairing…'**
  String get pairingInProgress;

  /// Pairing error: invalid or expired code.
  ///
  /// In en, this message translates to:
  /// **'The code is wrong or has expired. Get a new one on the PC.'**
  String get pairingErrorCode;

  /// Pairing error: rate limit (5 a minute).
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Wait a minute and try again.'**
  String get pairingErrorTooMany;

  /// Pairing error: network or wrong address.
  ///
  /// In en, this message translates to:
  /// **'The server does not answer. Check the address and the network.'**
  String get pairingErrorUnreachable;

  /// Pairing error: the license blocks the club.
  ///
  /// In en, this message translates to:
  /// **'The club\'s access has ended. Contact the administrator.'**
  String get pairingErrorLicense;

  /// Pairing error with the server's error code.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed ({code}).'**
  String pairingErrorOther(String code);

  /// A scanned QR code that is not ours.
  ///
  /// In en, this message translates to:
  /// **'This is not a PokerCam pairing code.'**
  String get pairingQrNotOurs;

  /// Shown on the pairing screen after the server dropped this phone (SPEC 6.4).
  ///
  /// In en, this message translates to:
  /// **'This phone was replaced by another one or unpaired. Pair it again.'**
  String get pairingReplaced;

  /// Pre-flight check screen title (SPEC 6.1).
  ///
  /// In en, this message translates to:
  /// **'Before streaming'**
  String get preflightTitle;

  /// Section: which camera parameters this phone supports.
  ///
  /// In en, this message translates to:
  /// **'Camera settings'**
  String get preflightCamera;

  /// Section: resolution and codec.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get preflightVideo;

  /// Section: permissions, battery, license.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get preflightSystem;

  /// Camera parameter.
  ///
  /// In en, this message translates to:
  /// **'Focus'**
  String get paramFocus;

  /// Camera parameter.
  ///
  /// In en, this message translates to:
  /// **'ISO'**
  String get paramIso;

  /// Camera parameter (exposure time).
  ///
  /// In en, this message translates to:
  /// **'Exposure'**
  String get paramExposure;

  /// Camera parameter (exposure compensation).
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get paramBrightness;

  /// Camera parameter.
  ///
  /// In en, this message translates to:
  /// **'Contrast'**
  String get paramContrast;

  /// Camera parameter.
  ///
  /// In en, this message translates to:
  /// **'White balance'**
  String get paramWhiteBalance;

  /// Camera parameter.
  ///
  /// In en, this message translates to:
  /// **'Zoom'**
  String get paramZoom;

  /// A camera parameter this phone can change.
  ///
  /// In en, this message translates to:
  /// **'supported'**
  String get supported;

  /// A camera parameter this phone cannot change; the PC blocks it.
  ///
  /// In en, this message translates to:
  /// **'not supported'**
  String get notSupported;

  /// Check: the camera gives 1080p.
  ///
  /// In en, this message translates to:
  /// **'Resolution 1920×1080'**
  String get preflightResolution;

  /// Detail under the resolution check.
  ///
  /// In en, this message translates to:
  /// **'the camera gives {size}'**
  String preflightResolutionActual(String size);

  /// Check: the phone can encode H.264 (needed for rewind, SPEC 6.3).
  ///
  /// In en, this message translates to:
  /// **'H.264 encoder'**
  String get preflightCodec;

  /// Detail when the phone has no H.264 encoder.
  ///
  /// In en, this message translates to:
  /// **'no H.264: live works, rewind does not'**
  String get preflightCodecMissing;

  /// Check: camera permission.
  ///
  /// In en, this message translates to:
  /// **'Camera access'**
  String get preflightCameraPermission;

  /// Check: notification permission for the foreground service.
  ///
  /// In en, this message translates to:
  /// **'Notifications (to keep streaming in the background)'**
  String get preflightNotifications;

  /// Check: the app is exempt from battery optimization (SPEC 6.3).
  ///
  /// In en, this message translates to:
  /// **'No battery restrictions'**
  String get preflightBattery;

  /// Check: the club's license.
  ///
  /// In en, this message translates to:
  /// **'Access'**
  String get preflightLicense;

  /// License detail.
  ///
  /// In en, this message translates to:
  /// **'active until {date}'**
  String licenseActive(String date);

  /// License detail during the 3-day grace period.
  ///
  /// In en, this message translates to:
  /// **'payment overdue: ends {date}'**
  String licenseGrace(String date);

  /// License detail: expired or suspended.
  ///
  /// In en, this message translates to:
  /// **'blocked'**
  String get licenseBlocked;

  /// Marks a check that must pass before streaming.
  ///
  /// In en, this message translates to:
  /// **'required'**
  String get preflightRequired;

  /// Button that asks for a missing permission or exemption.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get preflightFix;

  /// Button that runs the checks again.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get preflightRecheck;

  /// Button, active only when every required check passes.
  ///
  /// In en, this message translates to:
  /// **'Start streaming'**
  String get preflightStart;

  /// Button: forget the table and go back to pairing.
  ///
  /// In en, this message translates to:
  /// **'Unpair this phone'**
  String get unpair;

  /// Confirmation before unpairing.
  ///
  /// In en, this message translates to:
  /// **'This phone will stop being the table\'s camera. Continue?'**
  String get unpairConfirm;

  /// Dialog button.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Dialog button.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get confirm;

  /// Badge over the preview while the stream is published.
  ///
  /// In en, this message translates to:
  /// **'LIVE'**
  String get liveBadge;

  /// Broadcast status before the first publish.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get statusConnecting;

  /// Broadcast status after the connection was lost.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get statusReconnecting;

  /// Bitrate on the broadcast screen.
  ///
  /// In en, this message translates to:
  /// **'{kbps} kbit/s'**
  String statsBitrate(int kbps);

  /// Frame rate on the broadcast screen.
  ///
  /// In en, this message translates to:
  /// **'{fps} fps'**
  String statsFps(int fps);

  /// Battery level on the broadcast screen.
  ///
  /// In en, this message translates to:
  /// **'{pct} %'**
  String statsBattery(int pct);

  /// Battery temperature on the broadcast screen.
  ///
  /// In en, this message translates to:
  /// **'{temp} °C'**
  String statsTemperature(String temp);

  /// Network type.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi'**
  String get networkWifi;

  /// Network type.
  ///
  /// In en, this message translates to:
  /// **'Mobile network'**
  String get networkCellular;

  /// Network type.
  ///
  /// In en, this message translates to:
  /// **'Ethernet'**
  String get networkEthernet;

  /// Network type.
  ///
  /// In en, this message translates to:
  /// **'No network'**
  String get networkNone;

  /// Banner over the preview while reconnecting (SPEC 6.4).
  ///
  /// In en, this message translates to:
  /// **'No connection to the server. Reconnecting…'**
  String get bannerNoConnection;

  /// Banner when the license blocks the table.
  ///
  /// In en, this message translates to:
  /// **'The club\'s access is blocked: streaming stopped.'**
  String get bannerLicenseBlocked;

  /// Banner during the grace period.
  ///
  /// In en, this message translates to:
  /// **'Payment overdue: access ends {date}.'**
  String bannerLicenseGrace(String date);

  /// Button that stops streaming and goes back to the check.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stopStreaming;

  /// device.alert message_key (SPEC 6.4, overheating warning), shown on the phone and the PC.
  ///
  /// In en, this message translates to:
  /// **'The camera phone is overheating: video quality is reduced.'**
  String get alertOverheating;

  /// device.alert message_key (overheating critical).
  ///
  /// In en, this message translates to:
  /// **'The camera phone is badly overheated: video quality is strongly reduced.'**
  String get alertOverheatingCritical;

  /// device.alert message_key (overheating info, bitrate back to 4 Mbit/s).
  ///
  /// In en, this message translates to:
  /// **'The camera phone has cooled down: video quality is restored.'**
  String get alertCooledDown;

  /// device.alert message_key (low_battery warning).
  ///
  /// In en, this message translates to:
  /// **'The camera phone\'s battery is below 15 %. Plug in the charger.'**
  String get alertLowBattery;

  /// device.alert message_key (low_battery critical).
  ///
  /// In en, this message translates to:
  /// **'The camera phone\'s battery is below 5 %: streaming will stop soon.'**
  String get alertBatteryCritical;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
