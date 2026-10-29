import 'package:camera2_webrtc/self_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> cap({
    List<String> modes = const ['auto', 'manual'],
    double min = 0,
    double max = 10,
    List<String> presets = const [],
  }) => {
    'supported': true,
    'modes': modes,
    'min': min,
    'max': max,
    'step': 1.0,
    'presets': presets,
  };

  test('targets stay inside the camera range', () {
    expect(targetFor('iso', cap(min: 100, max: 3200))!.value, 875);
    expect(
      targetFor('exposure', cap(min: 100000, max: 1e9 / 30))!.value,
      closeTo(1e9 / 60, 1),
    );
    expect(targetFor('exposure', cap(min: 100000, max: 1e7))!.value, 1e7);
    expect(targetFor('zoom', cap(min: 1, max: 1.5))!.value, 1.5);
    expect(targetFor('focus', cap(min: 0, max: 10))!.value, 5);
  });

  test(
    'white balance prefers the daylight preset, then a manual temperature',
    () {
      expect(
        targetFor(
          'white_balance',
          cap(modes: ['auto', 'preset'], presets: ['daylight']),
        )!.preset,
        'daylight',
      );
      expect(
        targetFor(
          'white_balance',
          cap(modes: ['auto', 'manual'], min: 2000, max: 9000),
        )!.value,
        4000,
      );
      expect(targetFor('white_balance', cap(modes: ['auto'])), isNull);
    },
  );
}
