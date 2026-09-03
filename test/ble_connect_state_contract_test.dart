import 'package:flutter_ezw_ble/flutter_ezw_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('securityRecoveryExhausted decodes as a silent non-error terminal', () {
    final state = BleConnectStateExt.label('securityRecoveryExhausted');

    expect(state, BleConnectState.securityRecoveryExhausted);
    expect(state.isSecurityRecoveryExhausted, isTrue);
    expect(state.isError, isFalse);
    expect(state.isConnectError, isFalse);
    expect(state.isDisconnected, isFalse);
    expect(state.isConnecting, isFalse);
  });
}
