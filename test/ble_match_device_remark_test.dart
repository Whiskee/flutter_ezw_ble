import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ezw_ble/core/models/ble_match_device.dart';

void main() {
  for (final remark in ['MyGlasses', '', 'sn', 'devices', 'remark']) {
    test('remark round trip preserves identity: "$remark"', () {
      final original = BleMatchDevice('fixture-sn')..remark = remark;
      final json = jsonDecode(original.toString()) as Map<String, dynamic>;
      expect(json['sn'], 'fixture-sn');
      expect(json['devices'], isEmpty);
      expect(json['remark'], remark);
      expect(
          json.keys.toSet(), {'sn', 'devices', 'remark', 'isPureScanResult'});
      final restored = BleMatchDevice.fromJson(json);
      expect(restored.sn, original.sn);
      expect(restored.remark, remark);
    });
  }
  test('legacy cache without remark remains readable', () {
    expect(
        BleMatchDevice.fromJson({'sn': 'fixture', 'devices': []}).remark, '');
  });
  test('raw route survives decoding, copy and serialization', () {
    final raw = BleMatchDevice.fromJson({
      'sn': 'raw-shell',
      'devices': [],
      'isPureScanResult': true,
    });
    expect(raw.isPureScanResult, isTrue);
    final copy = raw.copy();
    expect(copy.isPureScanResult, isTrue);
    expect(BleMatchDevice.fromJson(copy.toJson()).isPureScanResult, isTrue);
    expect(
        BleMatchDevice.fromJson({'sn': 'legacy', 'devices': []})
            .isPureScanResult,
        isFalse);
  });
}
