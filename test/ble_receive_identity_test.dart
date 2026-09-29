import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ezw_ble/core/models/ble_cmd.dart';
import 'package:flutter_ezw_ble/core/models/ble_receive_identity.dart';
import 'package:flutter_ezw_ble/core/models/ble_business_connection_attempt.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('receive map trusts only the separately signed native identity', () {
    final cmd = BleCmd.receiveMap({
      'uuid': 'ring',
      'psType': 0,
      'data': 'AQID',
      'isSuccess': true,
      'sessionGeneration': 7,
      'attemptGeneration': 11,
      'receiveIdentity': {
        'uuid': 'ring',
        'sessionGeneration': 17,
        'attemptGeneration': 21,
      },
    });
    expect(cmd.toJson()['receiveIdentity'], {
      'uuid': 'ring',
      'sessionGeneration': 17,
      'attemptGeneration': 21,
    });
    expect(cmd.sessionGeneration, 7);
    expect(cmd.attemptGeneration, 11);
  });
  test('legacy positive pair cannot manufacture receive identity', () {
    final cmd = BleCmd.receiveMap({
      'uuid': 'ring',
      'sessionGeneration': 7,
      'attemptGeneration': 11,
    });
    expect(cmd.receiveIdentity, isNull);
  });
  test('unknown malformed and aliased receipt metadata stays precise', () {
    for (final pair in [
      <String, Object>{},
      {'sessionGeneration': 7},
      {'sessionGeneration': 0, 'attemptGeneration': 1},
      {'sessionGeneration': 1.5, 'attemptGeneration': 1},
      {'sessionGeneration': '7', 'attemptGeneration': 1}
    ]) {
      expect(
          BleCmd.receiveMap({'uuid': 'ring', ...pair}).receiveIdentity, isNull);
    }
    final original = BleCmd.receiveMap({
      'a': 'ring',
      'b': 2,
      'c': 'AQID',
      'd': true,
      'receiveIdentity': {
        'uuid': 'ring',
        'sessionGeneration': 7,
        'attemptGeneration': 11,
      },
    });
    expect(
        BleCmd.fromJson(original.toJson()).receiveIdentity,
        const BleReceiveIdentity(
            uuid: 'ring', sessionGeneration: 7, attemptGeneration: 11));
    expect(original.data, [1, 2, 3]);
  });
  test('strict send preserves expected map, rejects invalid, legacy omits it',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_ezw_ble'),
            (call) async {
      calls.add(call);
      return null;
    });
    final channel = MethodChannelEzwBle();
    await channel.sendCmd('ring', Uint8List.fromList([1]),
        expectedAttempt: const BleBusinessConnectionAttempt(
            uuid: 'ring', sessionGeneration: 7, attemptGeneration: 11));
    expect(calls.single.arguments['expectedAttempt'],
        {'uuid': 'ring', 'sessionGeneration': 7, 'attemptGeneration': 11});
    await channel.sendCmd('ring', Uint8List.fromList([2]));
    expect(
        (calls.last.arguments as Map).containsKey('expectedAttempt'), isFalse);
    await expectLater(
        channel.sendCmd('ring', Uint8List(0),
            expectedAttempt: const BleBusinessConnectionAttempt(
                uuid: 'other', sessionGeneration: 7, attemptGeneration: 11)),
        throwsArgumentError);
    expect(calls, hasLength(2));
  });
}
