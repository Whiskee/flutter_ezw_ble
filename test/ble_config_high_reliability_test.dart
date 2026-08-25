import 'package:flutter_ezw_ble/core/models/ble_config.dart';
import 'package:flutter_ezw_ble/core/models/ble_private_service.dart';
import 'package:flutter_ezw_ble/core/models/ble_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BleConfig config({bool highReliabilityMode = false}) => BleConfig(
        'test',
        BleScan(const ['TEST']),
        [
          BlePrivateService(
            '00000000-0000-0000-0000-000000000001',
            writeChars: '00000000-0000-0000-0000-000000000002',
            readChars: '00000000-0000-0000-0000-000000000003',
          ),
        ],
        androidHighReliabilityMode: highReliabilityMode,
      );

  test('Android high reliability mode is opt-in and survives JSON transport',
      () {
    expect(config().androidHighReliabilityMode, isFalse);

    final json = config(highReliabilityMode: true).customToJson();
    expect(json['androidHighReliabilityMode'], isTrue);
    expect(BleConfig.fromJson(json).androidHighReliabilityMode, isTrue);
  });
}
