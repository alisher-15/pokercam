#!/usr/bin/env bash
# Runs the spike's integration test on the CI emulator and keeps its report in build/.
set -uo pipefail
cd "$(dirname "$0")/.."
PKG=com.example.camera2_webrtc
mkdir -p build

# Install once with every runtime permission granted (-g); `flutter test` then updates the same
# package in place, which keeps the permission, so no dialog stops the test.
flutter build apk --debug
adb install -r -g build/app/outputs/flutter-apk/app-debug.apk
# Backup in case the update drops it: grant again as soon as the package is there.
(for _ in $(seq 1 600); do adb shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1; sleep 0.2; done) &
granter=$!

flutter test integration_test/spike_test.dart -d emulator-5554 --reporter expanded 2>&1 | tee build/spike-test.log
status=${PIPESTATUS[0]}
kill "$granter" 2>/dev/null

# The report is printed between markers; logcat prefixes may precede each line.
sed -n '/SPIKE_REPORT_BEGIN/,/SPIKE_REPORT_END/p' build/spike-test.log | sed '1d;$d' |
  sed -E 's/^.*I\/flutter *\( *[0-9]+\): //' > build/spike-report.json
exit "$status"
