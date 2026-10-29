import 'package:camera_android/src/policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  final t0 = DateTime(2026, 10, 29, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('heat (SPEC 6.4)', () {
    test('MODERATE: 3 Mbit/s and a warning; SEVERE: 2 Mbit/s, critical', () {
      final policy = ThermalPolicy();
      expect(policy.bitrate, 4000000);
      expect(policy.update(ThermalStatus.LIGHT, 35, at(0)), isNull);
      expect(
        policy.update(ThermalStatus.MODERATE, 35, at(5))?.messageKey,
        'alertOverheating',
      );
      expect(policy.bitrate, 3000000);
      final critical = policy.update(ThermalStatus.SEVERE, 35, at(10));
      expect(critical?.level, AlertLevel.CRITICAL);
      expect(policy.bitrate, 2000000);
      expect(policy.update(ThermalStatus.CRITICAL, 35, at(15)), isNull);
    });

    test('a battery above 42 °C counts as MODERATE', () {
      final policy = ThermalPolicy();
      expect(
        policy.update(ThermalStatus.NONE, 42.5, at(0))?.kind,
        AlertKind.OVERHEATING,
      );
      expect(policy.bitrate, 3000000);
    });

    test('back to 4 Mbit/s only after 2 minutes cooler, without see-saw', () {
      final policy = ThermalPolicy();
      policy.update(ThermalStatus.SEVERE, 35, at(0));
      expect(policy.update(ThermalStatus.NONE, 35, at(5)), isNull);
      expect(policy.update(ThermalStatus.NONE, 35, at(100)), isNull);
      // A hot reading in between starts the 2 minutes again.
      expect(policy.update(ThermalStatus.SEVERE, 35, at(110)), isNull);
      expect(policy.update(ThermalStatus.NONE, 35, at(115)), isNull);
      expect(policy.update(ThermalStatus.NONE, 35, at(230)), isNull);
      final cooled = policy.update(ThermalStatus.NONE, 35, at(236));
      expect(cooled?.messageKey, 'alertCooledDown');
      expect(cooled?.level, AlertLevel.INFO);
      expect(policy.bitrate, 4000000);
    });

    test('cooling down from SEVERE to MODERATE settles at 3 Mbit/s', () {
      final policy = ThermalPolicy();
      policy.update(ThermalStatus.SEVERE, 35, at(0));
      policy.update(ThermalStatus.MODERATE, 35, at(5));
      policy.update(ThermalStatus.NONE, 35, at(60));
      expect(
        policy.update(ThermalStatus.NONE, 35, at(125))?.messageKey,
        'alertOverheating',
      );
      expect(policy.bitrate, 3000000);
    });
  });

  group('battery (SPEC 6.4)', () {
    test('below 15 % a warning, below 5 % again (critical), each once', () {
      final policy = BatteryPolicy();
      expect(policy.update(50, false), isNull);
      expect(policy.update(14, false), BatteryPolicy.warning);
      expect(policy.banner, BatteryPolicy.warning);
      expect(policy.update(12, false), isNull);
      expect(policy.update(4, false), BatteryPolicy.critical);
      expect(policy.banner, BatteryPolicy.critical);
      expect(policy.update(3, false), isNull);
    });

    test('the charger clears the banner and arms the alerts again', () {
      final policy = BatteryPolicy();
      policy.update(10, false);
      expect(policy.update(10, true), isNull);
      expect(policy.banner, isNull);
      expect(policy.update(10, false), BatteryPolicy.warning);
    });
  });
}
