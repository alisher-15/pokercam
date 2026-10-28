import 'dart:async';
import 'dart:math';

import 'camera2.dart';
import 'loopback.dart';

/// Order of the checks; ISO and focus are what stage 1 must prove (SPEC 12).
const params = [
  'iso',
  'focus',
  'zoom',
  'exposure',
  'brightness',
  'contrast',
  'white_balance',
];

/// SPEC 6.5: a change must show up within 1 s.
const maxApplyMs = 1000;

/// A setting that differs from the defaults, inside the camera's range.
({String mode, double? value, String? preset})? targetFor(
  String param,
  Map<String, dynamic> cap,
) {
  final modes = (cap['modes'] as List).cast<String>();
  final lo = (cap['min'] as num?)?.toDouble() ?? 0;
  final hi = (cap['max'] as num?)?.toDouble() ?? 0;
  double within(double v) => v.clamp(lo, hi).toDouble();
  switch (param) {
    case 'iso':
      return (
        mode: 'manual',
        value: within((lo + (hi - lo) * 0.25).roundToDouble()),
        preset: null,
      );
    case 'exposure':
      return (mode: 'manual', value: within(1e9 / 60), preset: null);
    case 'focus':
      return (mode: 'manual', value: within(hi / 2), preset: null);
    case 'zoom':
      return (mode: 'manual', value: within(min(2.0, hi)), preset: null);
    case 'brightness':
      return (mode: 'manual', value: within(2), preset: null);
    case 'contrast':
      return (mode: 'manual', value: within(25), preset: null);
    case 'white_balance':
      final presets = (cap['presets'] as List).cast<String>();
      if (presets.contains('daylight')) {
        return (mode: 'preset', value: null, preset: 'daylight');
      }
      if (modes.contains('manual')) {
        return (mode: 'manual', value: within(4000), preset: null);
      }
      return null;
  }
  return null;
}

/// Sets every supported parameter while the stream runs and checks the camera reports it applied.
/// The same report comes from the app's «Автотест» button and from the CI emulator test.
Future<Map<String, dynamic>> runSelfTest(
  LoopbackSession session,
  Camera2 camera, {
  void Function(String line)? log,
}) async {
  final trackId = session.videoTrack.id!;
  final report = <String, dynamic>{
    'approach':
        'a: replace the repeating request of flutter_webrtc\'s Camera2 session',
    'device': await camera.deviceInfo(),
  };
  final caps = await camera.capabilities(trackId);
  report['camera'] = caps;
  // Let the stream settle before measuring.
  await Future<void>.delayed(const Duration(seconds: 2));
  final before = await session.stats();

  final results = <String, dynamic>{};
  for (final param in params) {
    final cap =
        (caps['params'] as Map<String, dynamic>)[param] as Map<String, dynamic>;
    final target = cap['supported'] == true ? targetFor(param, cap) : null;
    if (target == null) {
      results[param] = {'supported': false};
      log?.call('$param: не поддерживается');
      continue;
    }
    try {
      // Each parameter from all-automatic, so one manual setting does not change how another behaves.
      await camera.reset(trackId);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final requested = await camera.set(
        trackId,
        param,
        target.mode,
        value: target.value,
        preset: target.preset,
      );
      final appliedMs = await _waitApplied(camera, param);
      final state = await camera.state();
      results[param] = {
        'supported': true,
        'requested': requested,
        'applied': appliedMs != null,
        'within_1s': appliedMs != null && appliedMs <= maxApplyMs,
        'applied_after_ms': appliedMs,
        'camera_reports': (state['result'] as Map<String, dynamic>)[param],
        if (state['error'] != null) 'error': state['error'],
      };
      log?.call(
        '$param: ${appliedMs == null ? 'НЕ применился' : 'применился за $appliedMs мс'}',
      );
    } catch (e) {
      results[param] = {'supported': true, 'applied': false, 'error': '$e'};
      log?.call('$param: ошибка $e');
    }
  }

  await camera.reset(trackId);
  await Future<void>.delayed(const Duration(seconds: 2));
  final after = await session.stats();
  final decoded =
      (after['frames_decoded'] as num) - (before['frames_decoded'] as num);
  report['results'] = results;
  report['stream'] = {
    'before': before,
    'after': after,
    'frames_decoded_during_test': decoded,
  };
  final supported = results.values.where((r) => r['supported'] == true);
  // On a phone every setting must apply within 1 s (SPEC 6.5); the emulator only proves the mechanism.
  report['passed'] =
      decoded > 0 &&
      supported.isNotEmpty &&
      supported.every((r) => r['within_1s'] == true);
  return report;
}

Future<int?> _waitApplied(Camera2 camera, String param) async {
  final deadline = DateTime.now().add(
    const Duration(milliseconds: maxApplyMs * 3),
  );
  while (DateTime.now().isBefore(deadline)) {
    final applied =
        (await camera.state())['applied_after_ms'] as Map<String, dynamic>;
    if (applied[param] != null) return (applied[param] as num).toInt();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return null;
}
