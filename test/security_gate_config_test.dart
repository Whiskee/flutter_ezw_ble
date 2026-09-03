import 'package:flutter_ezw_ble/core/models/ble_config.dart';
import 'package:flutter_ezw_ble/core/models/ble_private_service.dart';
import 'package:flutter_ezw_ble/core/models/ble_scan.dart';
import 'package:flutter_ezw_ble/core/models/ble_security_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('security gate survives native config serialization', () {
    final config = BleConfig(
      'g2_glasses',
      BleScan(const <String>['Even G2']),
      <BlePrivateService>[
        BlePrivateService(
          '00002760-08C2-11E1-9073-0E8AC72E5450',
          writeChars: '00002760-08C2-11E1-9073-0E8AC72E5401',
          readChars: '00002760-08C2-11E1-9073-0E8AC72E5402',
        ),
      ],
      securityGate: const BleSecurityGate(
        service: '00002760-08C2-11E1-9073-0E8AC72E5450',
        writeChars: '00002760-08C2-11E1-9073-0E8AC72E5403',
      ),
    );

    final json = config.customToJson();
    expect(json['securityGate'], <String, Object>{
      'service': '00002760-08C2-11E1-9073-0E8AC72E5450',
      'writeChars': '00002760-08C2-11E1-9073-0E8AC72E5403',
    });

    final restored = BleConfig.fromJson(json);
    expect(restored.securityGate?.service, config.securityGate?.service);
    expect(restored.securityGate?.writeChars, config.securityGate?.writeChars);
  });
}
