import 'package:camera_android/src/media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';

void main() {
  test('the camera encoding: one layer at the bitrate cap, 30 fps, with the scalability mode the library needs', () {
    final encoding = cameraEncoding(4000000);
    expect(encoding.maxBitrate, 4000000);
    expect(encoding.maxFramerate, 30);
    final layers = ScalabilityMode.parse(encoding.scalabilityMode!);
    expect((layers.spatialLayers, layers.temporalLayers), (1, 1));
  });
}
