// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get cameraAppTitle => 'Table camera';

  @override
  String get viewerAppTitle => 'Table viewer';

  @override
  String get underConstruction => 'This screen is under construction.';

  @override
  String get pairingTitle => 'Pair with a table';

  @override
  String get pairingScanHint =>
      'Point the camera at the QR code from “Pair a phone” in the Windows app.';

  @override
  String get pairingManual => 'Enter the code';

  @override
  String get pairingScan => 'Scan the QR code';

  @override
  String get pairingServerLabel => 'Server address';

  @override
  String get pairingCodeLabel => '6-digit code';

  @override
  String get pairingSubmit => 'Pair';

  @override
  String get pairingInProgress => 'Pairing…';

  @override
  String get pairingErrorCode =>
      'The code is wrong or has expired. Get a new one on the PC.';

  @override
  String get pairingErrorTooMany =>
      'Too many attempts. Wait a minute and try again.';

  @override
  String get pairingErrorUnreachable =>
      'The server does not answer. Check the address and the network.';

  @override
  String get pairingErrorLicense =>
      'The club\'s access has ended. Contact the administrator.';

  @override
  String pairingErrorOther(String code) {
    return 'Pairing failed ($code).';
  }

  @override
  String get pairingQrNotOurs => 'This is not a PokerCam pairing code.';

  @override
  String get pairingReplaced =>
      'This phone was replaced by another one or unpaired. Pair it again.';

  @override
  String get preflightTitle => 'Before streaming';

  @override
  String get preflightCamera => 'Camera settings';

  @override
  String get preflightVideo => 'Video';

  @override
  String get preflightSystem => 'Phone';

  @override
  String get paramFocus => 'Focus';

  @override
  String get paramIso => 'ISO';

  @override
  String get paramExposure => 'Exposure';

  @override
  String get paramBrightness => 'Brightness';

  @override
  String get paramContrast => 'Contrast';

  @override
  String get paramWhiteBalance => 'White balance';

  @override
  String get paramZoom => 'Zoom';

  @override
  String get supported => 'supported';

  @override
  String get notSupported => 'not supported';

  @override
  String get preflightResolution => 'Resolution 1920×1080';

  @override
  String preflightResolutionActual(String size) {
    return 'the camera gives $size';
  }

  @override
  String get preflightCodec => 'H.264 encoder';

  @override
  String get preflightCodecMissing => 'no H.264: live works, rewind does not';

  @override
  String get preflightCameraPermission => 'Camera access';

  @override
  String get preflightNotifications =>
      'Notifications (to keep streaming in the background)';

  @override
  String get preflightBattery => 'No battery restrictions';

  @override
  String get preflightLicense => 'Access';

  @override
  String licenseActive(String date) {
    return 'active until $date';
  }

  @override
  String licenseGrace(String date) {
    return 'payment overdue: ends $date';
  }

  @override
  String get licenseBlocked => 'blocked';

  @override
  String get preflightRequired => 'required';

  @override
  String get preflightFix => 'Allow';

  @override
  String get preflightRecheck => 'Check again';

  @override
  String get preflightStart => 'Start streaming';

  @override
  String get unpair => 'Unpair this phone';

  @override
  String get unpairConfirm =>
      'This phone will stop being the table\'s camera. Continue?';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'Continue';

  @override
  String get liveBadge => 'LIVE';

  @override
  String get statusConnecting => 'Connecting…';

  @override
  String get statusReconnecting => 'Reconnecting…';

  @override
  String statsBitrate(int kbps) {
    return '$kbps kbit/s';
  }

  @override
  String statsFps(int fps) {
    return '$fps fps';
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
  String get networkCellular => 'Mobile network';

  @override
  String get networkEthernet => 'Ethernet';

  @override
  String get networkNone => 'No network';

  @override
  String get bannerNoConnection => 'No connection to the server. Reconnecting…';

  @override
  String get bannerLicenseBlocked =>
      'The club\'s access is blocked: streaming stopped.';

  @override
  String bannerLicenseGrace(String date) {
    return 'Payment overdue: access ends $date.';
  }

  @override
  String get stopStreaming => 'Stop';

  @override
  String get alertOverheating =>
      'The camera phone is overheating: video quality is reduced.';

  @override
  String get alertOverheatingCritical =>
      'The camera phone is badly overheated: video quality is strongly reduced.';

  @override
  String get alertCooledDown =>
      'The camera phone has cooled down: video quality is restored.';

  @override
  String get alertLowBattery =>
      'The camera phone\'s battery is below 15 %. Plug in the charger.';

  @override
  String get alertBatteryCritical =>
      'The camera phone\'s battery is below 5 %: streaming will stop soon.';

  @override
  String get pairingCameraDenied =>
      'No camera access — enter the code by hand.';

  @override
  String get pairingServerHint => 'https://cam.club.kz';

  @override
  String get serviceChannel => 'Streaming';

  @override
  String get serviceTitle => 'The table camera is on air';

  @override
  String get serviceText => 'Streaming to the server. Keep the app open.';

  @override
  String preflightCameraError(String error) {
    return 'The camera did not open: $error';
  }

  @override
  String get preflightLicenseUnknown =>
      'cannot check: no connection to the server';

  @override
  String get activationTitle => 'Connect this computer';

  @override
  String get activationServerLabel => 'Server address';

  @override
  String get activationKeyLabel => 'Club activation key';

  @override
  String get activationNameLabel => 'This computer\'s name';

  @override
  String get activationNameDefault => 'Club PC';

  @override
  String get activationSubmit => 'Connect';

  @override
  String get activationErrorKey => 'Wrong activation key.';

  @override
  String get errorTooMany => 'Too many attempts: wait a minute and try again.';

  @override
  String get errorUnreachable =>
      'The server cannot be reached. Check the address and the network.';

  @override
  String get errorRevoked =>
      'This computer was disconnected in the admin panel. Connect it again.';

  @override
  String get errorLicense =>
      'The club\'s access is blocked. Contact your seller to renew it.';

  @override
  String errorOther(String code) {
    return 'Something went wrong ($code).';
  }

  @override
  String get retry => 'Try again';

  @override
  String get tablesTitle => 'Tables';

  @override
  String tableName(int number) {
    return 'Table $number';
  }

  @override
  String get tableCameraOnline => 'camera on air';

  @override
  String get tableCameraOffline => 'no camera';

  @override
  String tableCameraLastSeen(String time) {
    return 'camera last seen $time';
  }

  @override
  String get tablesEmpty => 'The club has no tables.';

  @override
  String get tableOpen => 'Open';

  @override
  String get tableOpenWindow => 'In a new window';

  @override
  String get signOut => 'Sign out';

  @override
  String get pairPhone => 'Pair a phone';

  @override
  String pairPhoneTitle(int number) {
    return 'Pair a phone with table $number';
  }

  @override
  String get pairPhoneHint =>
      'In the camera app, point the camera at this QR code or enter the code by hand.';

  @override
  String pairPhoneServer(String url) {
    return 'Server: $url';
  }

  @override
  String pairPhoneExpires(String time) {
    return 'Valid until $time. The table\'s current phone stops when the new one pairs.';
  }

  @override
  String get pairPhoneNewCode => 'New code';

  @override
  String get close => 'Close';

  @override
  String get watchWaiting => 'Waiting for the table\'s camera…';

  @override
  String get watchCameraOffline => 'The camera is not online';

  @override
  String watchCameraOfflineSince(String time) {
    return 'The camera has been offline since $time';
  }

  @override
  String get watchRoomFull =>
      'Another computer is already watching this table.';

  @override
  String get panelCamera => 'Camera';

  @override
  String get panelDevice => 'Phone';

  @override
  String get panelAlerts => 'Alerts';

  @override
  String get alertsEmpty => 'No alerts yet';

  @override
  String get modeAuto => 'Auto';

  @override
  String get modeManual => 'Manual';

  @override
  String get modePreset => 'Preset';

  @override
  String get presetIncandescent => 'Incandescent';

  @override
  String get presetFluorescent => 'Fluorescent';

  @override
  String get presetWarmFluorescent => 'Warm fluorescent';

  @override
  String get presetDaylight => 'Daylight';

  @override
  String get presetCloudyDaylight => 'Cloudy';

  @override
  String get presetTwilight => 'Twilight';

  @override
  String get presetShade => 'Shade';

  @override
  String get resetDefaults => 'Reset to defaults';

  @override
  String get notSupportedHint => 'This phone\'s camera cannot change this';

  @override
  String cameraSetFailed(String param, String error) {
    return 'The camera did not apply $param: $error';
  }

  @override
  String get deviceBattery => 'Battery';

  @override
  String deviceBatteryValue(int pct) {
    return '$pct %';
  }

  @override
  String deviceCharging(int pct) {
    return '$pct %, charging';
  }

  @override
  String get deviceTemperature => 'Temperature';

  @override
  String deviceTemperatureValue(String temp) {
    return '$temp °C';
  }

  @override
  String get deviceNetwork => 'Network';

  @override
  String deviceSignal(int dbm) {
    return '$dbm dBm';
  }

  @override
  String deviceRtt(int ms) {
    return 'RTT $ms ms';
  }

  @override
  String get deviceBitrate => 'Bitrate';

  @override
  String get deviceFps => 'Frame rate';

  @override
  String get deviceDropped => 'Dropped frames';

  @override
  String get deviceConnection => 'Connection';

  @override
  String get connectionLive => 'on air';

  @override
  String get connectionOffline => 'camera offline';

  @override
  String get deviceNoData => 'no data from the phone yet';

  @override
  String get cameraNoAnswer => 'no answer from the camera';

  @override
  String cameraApplied(int ms) {
    return 'applied in $ms ms';
  }
}
