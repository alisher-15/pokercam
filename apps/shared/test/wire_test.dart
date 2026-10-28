import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  test('withoutNulls drops nulls at every level', () {
    final json = <String, dynamic>{
      'a': 1,
      'b': null,
      'c': {'d': null, 'e': 'x'},
      'f': [
        {'g': null, 'h': 2},
      ],
    };
    expect(withoutNulls(json), {
      'a': 1,
      'c': {'e': 'x'},
      'f': [
        {'h': 2},
      ],
    });
  });

  test('encodeWire leaves absent optional fields out', () {
    final message = CameraSetMessage(
      id: 'm-1',
      ts: 1,
      tableId: '3f1c2a9e-8b7d-4c61-9a52-0e4b7d2c1f88',
      type: CameraSetMessageType.CAMERA_SET,
      payload: CameraSetPayload(
        param: CameraParam.ISO,
        control: CameraControl(mode: ControlMode.AUTO),
      ),
    );
    final sent =
        jsonDecode(encodeWire(message.toJson())) as Map<String, dynamic>;
    expect(sent['payload'], {
      'param': 'iso',
      'control': {'mode': 'auto'},
    });
  });
}
