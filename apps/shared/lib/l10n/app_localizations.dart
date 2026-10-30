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

  /// Shown instead of the QR scanner when the camera cannot be used.
  ///
  /// In en, this message translates to:
  /// **'No camera access — enter the code by hand.'**
  String get pairingCameraDenied;

  /// Example server address in the manual pairing form.
  ///
  /// In en, this message translates to:
  /// **'https://cam.club.kz'**
  String get pairingServerHint;

  /// Android notification channel of the streaming service.
  ///
  /// In en, this message translates to:
  /// **'Streaming'**
  String get serviceChannel;

  /// Notification title while streaming (SPEC 6.3 foreground service).
  ///
  /// In en, this message translates to:
  /// **'The table camera is on air'**
  String get serviceTitle;

  /// Notification text while streaming.
  ///
  /// In en, this message translates to:
  /// **'Streaming to the server. Keep the app open.'**
  String get serviceText;

  /// Pre-flight: opening the camera failed.
  ///
  /// In en, this message translates to:
  /// **'The camera did not open: {error}'**
  String preflightCameraError(String error);

  /// License detail when the backend cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'cannot check: no connection to the server'**
  String get preflightLicenseUnknown;

  /// No description provided for @activationTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect this computer'**
  String get activationTitle;

  /// No description provided for @activationServerLabel.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get activationServerLabel;

  /// No description provided for @activationKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Club activation key'**
  String get activationKeyLabel;

  /// No description provided for @activationNameLabel.
  ///
  /// In en, this message translates to:
  /// **'This computer\'s name'**
  String get activationNameLabel;

  /// No description provided for @activationNameDefault.
  ///
  /// In en, this message translates to:
  /// **'Club PC'**
  String get activationNameDefault;

  /// No description provided for @activationSubmit.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get activationSubmit;

  /// No description provided for @activationErrorKey.
  ///
  /// In en, this message translates to:
  /// **'Wrong activation key.'**
  String get activationErrorKey;

  /// No description provided for @errorTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts: wait a minute and try again.'**
  String get errorTooMany;

  /// No description provided for @errorUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The server cannot be reached. Check the address and the network.'**
  String get errorUnreachable;

  /// No description provided for @errorRevoked.
  ///
  /// In en, this message translates to:
  /// **'This computer was disconnected in the admin panel. Connect it again.'**
  String get errorRevoked;

  /// No description provided for @errorLicense.
  ///
  /// In en, this message translates to:
  /// **'The club\'s access is blocked. Contact your seller to renew it.'**
  String get errorLicense;

  /// No description provided for @errorOther.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong ({code}).'**
  String errorOther(String code);

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get retry;

  /// No description provided for @tablesTitle.
  ///
  /// In en, this message translates to:
  /// **'Tables'**
  String get tablesTitle;

  /// No description provided for @tableName.
  ///
  /// In en, this message translates to:
  /// **'Table {number}'**
  String tableName(int number);

  /// No description provided for @tableCameraOnline.
  ///
  /// In en, this message translates to:
  /// **'camera on air'**
  String get tableCameraOnline;

  /// No description provided for @tableCameraOffline.
  ///
  /// In en, this message translates to:
  /// **'no camera'**
  String get tableCameraOffline;

  /// No description provided for @tableCameraLastSeen.
  ///
  /// In en, this message translates to:
  /// **'camera last seen {time}'**
  String tableCameraLastSeen(String time);

  /// No description provided for @tablesEmpty.
  ///
  /// In en, this message translates to:
  /// **'The club has no tables.'**
  String get tablesEmpty;

  /// No description provided for @tableOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get tableOpen;

  /// No description provided for @tableOpenWindow.
  ///
  /// In en, this message translates to:
  /// **'In a new window'**
  String get tableOpenWindow;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @pairPhone.
  ///
  /// In en, this message translates to:
  /// **'Pair a phone'**
  String get pairPhone;

  /// No description provided for @pairPhoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair a phone with table {number}'**
  String pairPhoneTitle(int number);

  /// No description provided for @pairPhoneHint.
  ///
  /// In en, this message translates to:
  /// **'In the camera app, point the camera at this QR code or enter the code by hand.'**
  String get pairPhoneHint;

  /// No description provided for @pairPhoneServer.
  ///
  /// In en, this message translates to:
  /// **'Server: {url}'**
  String pairPhoneServer(String url);

  /// No description provided for @pairPhoneExpires.
  ///
  /// In en, this message translates to:
  /// **'Valid until {time}. The table\'s current phone stops when the new one pairs.'**
  String pairPhoneExpires(String time);

  /// No description provided for @pairPhoneNewCode.
  ///
  /// In en, this message translates to:
  /// **'New code'**
  String get pairPhoneNewCode;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @watchWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the table\'s camera…'**
  String get watchWaiting;

  /// No description provided for @watchCameraOffline.
  ///
  /// In en, this message translates to:
  /// **'The camera is not online'**
  String get watchCameraOffline;

  /// No description provided for @watchCameraOfflineSince.
  ///
  /// In en, this message translates to:
  /// **'The camera has been offline since {time}'**
  String watchCameraOfflineSince(String time);

  /// No description provided for @watchRoomFull.
  ///
  /// In en, this message translates to:
  /// **'Another computer is already watching this table.'**
  String get watchRoomFull;

  /// No description provided for @panelCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get panelCamera;

  /// No description provided for @panelDevice.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get panelDevice;

  /// No description provided for @panelAlerts.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get panelAlerts;

  /// No description provided for @alertsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No alerts yet'**
  String get alertsEmpty;

  /// No description provided for @modeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get modeAuto;

  /// No description provided for @modeManual.
  ///
  /// In en, this message translates to:
  /// **'Manual'**
  String get modeManual;

  /// No description provided for @modePreset.
  ///
  /// In en, this message translates to:
  /// **'Preset'**
  String get modePreset;

  /// No description provided for @presetIncandescent.
  ///
  /// In en, this message translates to:
  /// **'Incandescent'**
  String get presetIncandescent;

  /// No description provided for @presetFluorescent.
  ///
  /// In en, this message translates to:
  /// **'Fluorescent'**
  String get presetFluorescent;

  /// No description provided for @presetWarmFluorescent.
  ///
  /// In en, this message translates to:
  /// **'Warm fluorescent'**
  String get presetWarmFluorescent;

  /// No description provided for @presetDaylight.
  ///
  /// In en, this message translates to:
  /// **'Daylight'**
  String get presetDaylight;

  /// No description provided for @presetCloudyDaylight.
  ///
  /// In en, this message translates to:
  /// **'Cloudy'**
  String get presetCloudyDaylight;

  /// No description provided for @presetTwilight.
  ///
  /// In en, this message translates to:
  /// **'Twilight'**
  String get presetTwilight;

  /// No description provided for @presetShade.
  ///
  /// In en, this message translates to:
  /// **'Shade'**
  String get presetShade;

  /// No description provided for @resetDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetDefaults;

  /// No description provided for @notSupportedHint.
  ///
  /// In en, this message translates to:
  /// **'This phone\'s camera cannot change this'**
  String get notSupportedHint;

  /// No description provided for @cameraSetFailed.
  ///
  /// In en, this message translates to:
  /// **'The camera did not apply {param}: {error}'**
  String cameraSetFailed(String param, String error);

  /// No description provided for @deviceBattery.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get deviceBattery;

  /// No description provided for @deviceBatteryValue.
  ///
  /// In en, this message translates to:
  /// **'{pct} %'**
  String deviceBatteryValue(int pct);

  /// No description provided for @deviceCharging.
  ///
  /// In en, this message translates to:
  /// **'{pct} %, charging'**
  String deviceCharging(int pct);

  /// No description provided for @deviceTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get deviceTemperature;

  /// No description provided for @deviceTemperatureValue.
  ///
  /// In en, this message translates to:
  /// **'{temp} °C'**
  String deviceTemperatureValue(String temp);

  /// No description provided for @deviceNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get deviceNetwork;

  /// No description provided for @deviceSignal.
  ///
  /// In en, this message translates to:
  /// **'{dbm} dBm'**
  String deviceSignal(int dbm);

  /// No description provided for @deviceRtt.
  ///
  /// In en, this message translates to:
  /// **'RTT {ms} ms'**
  String deviceRtt(int ms);

  /// No description provided for @deviceBitrate.
  ///
  /// In en, this message translates to:
  /// **'Bitrate'**
  String get deviceBitrate;

  /// No description provided for @deviceFps.
  ///
  /// In en, this message translates to:
  /// **'Frame rate'**
  String get deviceFps;

  /// No description provided for @deviceDropped.
  ///
  /// In en, this message translates to:
  /// **'Dropped frames'**
  String get deviceDropped;

  /// No description provided for @deviceConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get deviceConnection;

  /// No description provided for @connectionLive.
  ///
  /// In en, this message translates to:
  /// **'on air'**
  String get connectionLive;

  /// No description provided for @connectionOffline.
  ///
  /// In en, this message translates to:
  /// **'camera offline'**
  String get connectionOffline;

  /// No description provided for @deviceNoData.
  ///
  /// In en, this message translates to:
  /// **'no data from the phone yet'**
  String get deviceNoData;
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
