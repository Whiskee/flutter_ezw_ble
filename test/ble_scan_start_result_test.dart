import 'package:flutter_ezw_ble/core/models/ble_scan_start_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a confirmed native scan generation', () {
    final result = BleScanStartResult.fromNative(const {
      'started': true,
      'generation': 7,
      'reason': 'started',
    });

    expect(result.started, isTrue);
    expect(result.generation, 7);
    expect(result.reason, 'started');
  });

  test('malformed native result fails closed', () {
    final result = BleScanStartResult.fromNative(null);

    expect(result.started, isFalse);
    expect(result.generation, 0);
    expect(result.reason, 'invalidResult');
  });

  test('preserves async failure generation and Android error code', () {
    final result = BleScanStartResult.fromNative(const {
      'started': false,
      'generation': 11,
      'reason': 'asyncFailure',
      'errorCode': 2,
    });

    expect(result.started, isFalse);
    expect(result.generation, 11);
    expect(result.errorCode, 2);
  });
}
