import 'package:flutter_ezw_ble/core/models/ble_connect_model.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_source.dart';
import 'package:flutter_ezw_ble/core/models/ble_connect_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device-wake reconnect sources survive the Flutter wire model', () {
    for (final source in const <BleConnectSource>[
      BleConnectSource.androidCdm,
      BleConnectSource.androidBlePendingIntent,
    ]) {
      final encoded = BleConnectModel(
        'fixture-id',
        'fixture-name',
        BleConnectState.connected,
        source: source,
      ).toJson();
      expect(encoded['source'], source.name);
      expect(BleConnectModel.fromJson(encoded).source, source);
      expect(source.isAutomaticReconnect, isTrue);
    }
  });
}
