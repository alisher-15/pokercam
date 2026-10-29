// The report goes to the log (print) so CI can keep it as an artifact.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:camera2_webrtc/camera2.dart';
import 'package:camera2_webrtc/loopback.dart';
import 'package:camera2_webrtc/self_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Runs on the CI emulator (and on any phone with `flutter test integration_test`):
/// stream the camera, set every supported parameter, check the camera applied it in time.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manual camera settings apply while the stream runs', (
    tester,
  ) async {
    final session = await LoopbackSession.start();
    addTearDown(session.dispose);
    final report = await runSelfTest(
      session,
      Camera2(),
      log: (line) => print('spike: $line'),
    );

    // CI cuts the report out of the log between these markers and keeps it as an artifact.
    print('SPIKE_REPORT_BEGIN');
    const JsonEncoder.withIndent('  ')
        .convert(report)
        .split('\n')
        .forEach(print);
    print('SPIKE_REPORT_END');

    final stream = report['stream'] as Map<String, dynamic>;
    expect(
      stream['frames_decoded_during_test'],
      greaterThan(0),
      reason: 'the stream stopped while settings changed',
    );
    final results = (report['results'] as Map<String, dynamic>)
        .cast<String, Map<String, dynamic>>();
    final supported = results.entries
        .where((e) => e.value['supported'] == true)
        .toList();
    expect(
      supported,
      isNotEmpty,
      reason: 'the camera supports no manual setting at all',
    );
    // Every supported setting must apply while the stream runs. The 1 s budget is judged on a phone
    // (`passed` in the report): the emulator's camera runs at a few frames a second.
    for (final MapEntry(key: param, value: result) in supported) {
      expect(
        result['applied'],
        isTrue,
        reason: '$param: ${jsonEncode(result)}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
