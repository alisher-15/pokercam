import 'package:shared/shared.dart';

/// A device.alert to send and show (contracts/ws/control/device.alert.json): [messageKey] is an ARB key.
class Alert {
  const Alert(this.kind, this.level, this.messageKey);

  final AlertKind kind;
  final AlertLevel level;
  final String messageKey;

  Map<String, dynamic> toPayload() => {
    'kind': alertKindValues.reverse[kind],
    'level': alertLevelValues.reverse[level],
    'message_key': messageKey,
  };

  @override
  bool operator ==(Object other) =>
      other is Alert &&
      other.kind == kind &&
      other.level == level &&
      other.messageKey == messageKey;

  @override
  int get hashCode => Object.hash(kind, level, messageKey);

  @override
  String toString() => 'Alert($messageKey)';
}

/// SPEC 6.4, heat: MODERATE or a battery above 42 °C → 3 Mbit/s and a warning; SEVERE and worse → 2 Mbit/s,
/// critical. Back up only after the phone has stayed cooler for 2 minutes (hysteresis, no see-saw).
class ThermalPolicy {
  ThermalPolicy({this.cooldown = const Duration(minutes: 2)});

  static const bitrates = [4000000, 3000000, 2000000];
  static const hotBatteryC = 42.0;

  final Duration cooldown;
  int _level = 0;
  DateTime? _coolerSince;
  int _coolerMax = 0;

  /// 0 normal, 1 warm, 2 hot.
  int get level => _level;
  int get bitrate => bitrates[_level];

  /// Feeds the latest reading; returns the alert to send when the level changes.
  Alert? update(ThermalStatus thermal, double batteryC, DateTime now) {
    final target = _target(thermal, batteryC);
    if (target > _level) {
      _level = target;
      _coolerSince = null;
      return _alert();
    }
    if (target == _level) {
      _coolerSince = null;
      return null;
    }
    if (_coolerSince == null) {
      _coolerSince = now;
      _coolerMax = target;
    } else if (target > _coolerMax) {
      _coolerMax = target;
    }
    if (now.difference(_coolerSince!) < cooldown) return null;
    _level = _coolerMax;
    _coolerSince = null;
    return _alert();
  }

  static int _target(ThermalStatus thermal, double batteryC) =>
      switch (thermal) {
        ThermalStatus.SEVERE ||
        ThermalStatus.CRITICAL ||
        ThermalStatus.EMERGENCY ||
        ThermalStatus.SHUTDOWN => 2,
        ThermalStatus.MODERATE => 1,
        ThermalStatus.NONE ||
        ThermalStatus.LIGHT => batteryC > hotBatteryC ? 1 : 0,
      };

  Alert _alert() => switch (_level) {
    2 => const Alert(
      AlertKind.OVERHEATING,
      AlertLevel.CRITICAL,
      'alertOverheatingCritical',
    ),
    1 => const Alert(
      AlertKind.OVERHEATING,
      AlertLevel.WARNING,
      'alertOverheating',
    ),
    _ => const Alert(AlertKind.OVERHEATING, AlertLevel.INFO, 'alertCooledDown'),
  };
}

/// SPEC 6.4, battery: below 15 % without the charger a banner and a warning, again below 5 % (critical).
/// Charging, or 20 % and more, arms both again.
class BatteryPolicy {
  bool _warned = false;
  bool _critical = false;

  /// The banner the phone shows now, or null.
  Alert? banner;

  Alert? update(int pct, bool charging) {
    if (charging || pct >= 20) {
      _warned = false;
      _critical = false;
    }
    banner = charging || pct >= 15
        ? null
        : pct < 5
        ? critical
        : warning;
    if (!charging && pct < 5 && !_critical) {
      _critical = true;
      _warned = true;
      return critical;
    }
    if (!charging && pct < 15 && !_warned) {
      _warned = true;
      return warning;
    }
    return null;
  }

  static const warning = Alert(
    AlertKind.LOW_BATTERY,
    AlertLevel.WARNING,
    'alertLowBattery',
  );
  static const critical = Alert(
    AlertKind.LOW_BATTERY,
    AlertLevel.CRITICAL,
    'alertBatteryCritical',
  );
}
