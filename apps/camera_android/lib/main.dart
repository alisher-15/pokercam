import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'src/app.dart';
import 'src/media.dart';
import 'src/platform/camera2.dart';
import 'src/platform/device.dart';
import 'src/store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final log = JsonLog('camera');
  runApp(
    CameraApp(
      services: Services(
        pairings: SecurePairingStore(),
        settings: PreferencesSettingsStore(),
        camera: Camera2Channel(),
        device: DeviceChannel(),
        publisher: MediasoupPublisher(log),
        log: log,
      ),
    ),
  );
}
