import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/core/models/ble_config.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_model.dart';
import 'package:flutter_ezw_ble/core/models/ble_scan.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'legacy config keeps old timing and opt-in survives nested serialization',
      () {
    final legacy = BleConfig.fromJson({
      'name': 'old',
      'scan': BleScan(['G2']).customToJson(),
      'privateServices': <Object>[],
    });
    expect(legacy.androidBondTimeout, isNull);
    expect(legacy.androidSerializeUnbonded, isFalse);
    final json = BleConfig('g2', legacy.scan, [],
            androidBondTimeout: 30000, androidSerializeUnbonded: true)
        .customToJson();
    expect(json['androidBondTimeout'], 30000);
    expect(json['androidSerializeUnbonded'], isTrue);
    final restored = BleConfig.fromJson(json);
    expect(restored.androidBondTimeout, 30000);
    expect(restored.androidSerializeUnbonded, isTrue);
  });

  test('control progress preserves identity without contact or Trace', () {
    for (final phase in ['queuedBeforePhysical', 'bonding', 'bonded']) {
      final model = BleConnectModel.fromJson({
        'uuid': 'endpoint',
        'name': 'G2',
        'connectState': 'connecting',
        'source': 'foreground',
        'sessionGeneration': 101,
        'attemptGeneration': 7,
        'pairingPhase': phase,
      });
      expect(model.sessionGeneration, 101);
      expect(model.attemptGeneration, 7);
      expect(model.nativeTrace, isNull);
      expect(model.toJson()['pairingPhase'], phase);
    }
    final legacy = BleConnectModel.fromJson({
      'uuid': 'endpoint',
      'name': 'G2',
      'connectState': 'connecting',
    });
    expect(legacy.pairingPhase, isNull);
  });

  test('optional request session is forwarded only when explicitly supplied',
      () async {
    const channel = MethodChannel('flutter_ezw_ble');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = MethodChannelEzwBle();
    await bridge.connectDevice('g2', 'endpoint', 'G2', sn: 'SN');
    await bridge.connectDevice('g2', 'endpoint', 'G2',
        sn: 'SN', sessionGeneration: 101);
    expect((calls.first.arguments as Map).containsKey('sessionGeneration'),
        isFalse);
    expect((calls.last.arguments as Map)['sessionGeneration'], 101);
  });
}
