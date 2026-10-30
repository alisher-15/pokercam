#!/usr/bin/env bash
# Stage 5 acceptance on the CI emulator (SPEC 6.5): the app driven by integration_test/e2e_test.dart and the
# club's PC played by tools/acceptance/stage5.ts, against `make dev` on this machine.
# Needs HOST_IP (this machine's address, which the emulator reaches) and CLUB_KEY (a client's activation key).
set -uo pipefail
cd "$(dirname "$0")/.."
PKG=com.pokercam.camera
mkdir -p build

# Install once with every runtime permission granted (-g); `flutter test` then updates the same package in
# place. Granted again in a loop in case the update drops them, so no permission dialog stops the test.
flutter build apk --debug
adb install -r -g build/app/outputs/flutter-apk/app-debug.apk
# The emulator's default ring buffer is overwritten by its camera HAL within minutes.
adb logcat -G 16M >/dev/null 2>&1 || true
(for _ in $(seq 1 4000); do
  adb shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1
  adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
  sleep 0.3
done) &
granter=$!

(cd ../../tools && node acceptance/stage5.ts --key "$CLUB_KEY" --phone-api "http://$HOST_IP:8000" --port 8765) > build/harness.log 2>&1 &
harness=$!

# The emulator has no H.264 and encodes VP8 in software: at its camera's 1856x1392 the PC got under 10 frames
# in 90 s. SPEC 6.5's 1080p30 is checked on the reference phone; the flows here are the same at 640x480.
flutter test integration_test/e2e_test.dart -d emulator-5554 --dart-define=E2E_HARNESS="http://$HOST_IP:8765" \
  --dart-define=CAPTURE_WIDTH=640 --dart-define=CAPTURE_HEIGHT=480 --reporter expanded 2>&1 | tee build/e2e-test.log
app_status=${PIPESTATUS[0]}
wait "$harness"
harness_status=$?
kill "$granter" 2>/dev/null
adb logcat -d > build/logcat.txt 2>/dev/null
echo "--- the app's log and errors (logcat) ---"
grep -E 'flutter|Camera2Control|Camera2Session|CameraCapturer|Camera2Capturer|SurfaceTextureHelper|Camera2CameraImpl|CameraX|MobileScanner|AndroidRuntime|FATAL' \
  build/logcat.txt | grep -v '"message"' | tail -200
echo "--- who opened and lost the camera (camera service events) ---"
adb shell dumpsys media.camera 2>/dev/null | grep -E 'CONNECT|DISCONNECT|EVICT|DIED' | tail -40
echo "--- the PC harness ---"
cat build/harness.log
echo "app test: $app_status, harness: $harness_status"
[ "$app_status" -eq 0 ] && [ "$harness_status" -eq 0 ]
