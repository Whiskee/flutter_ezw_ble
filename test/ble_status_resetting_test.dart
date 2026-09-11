import 'package:flutter_ezw_ble/core/models/ble_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS CoreBluetooth resetting remains observable but transient', () {
    final state = BleStateExt.from(1);

    expect(state, BleState.resetting);
    expect(state.isBleUnknown, isTrue);
    expect(state.isBleAvailable, isFalse);
    expect(state.isBleOff, isFalse);
  });
}
