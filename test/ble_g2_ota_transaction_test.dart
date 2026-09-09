import 'package:flutter_ezw_ble/core/models/ble_g2_ota_transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const identity = <String, Object?>{
    'transactionId': 'tx-10',
    'generation': 10,
    'instanceId': 'native-instance',
  };

  test('only explicit valid committed results prove retirement', () {
    for (final status in BleG2OtaTransactionStatus.values) {
      final result = BleG2OtaTransactionResult.fromNative({
        ...identity,
        'status': status.name,
      });
      expect(
        result.isRetired,
        status == BleG2OtaTransactionStatus.committed ||
            status == BleG2OtaTransactionStatus.alreadyCommitted,
        reason: status.name,
      );
    }
  });

  test('malformed positive or invalidation replies cannot grant authority', () {
    final corruptions = <Map<String, Object?>>[
      {'transactionId': ''},
      {'transactionId': ' \t'},
      {'transactionId': 10},
      {'instanceId': ''},
      {'instanceId': '\n'},
      {'instanceId': false},
      {'generation': 0},
      {'generation': -1},
      {'generation': 10.0},
      {'generation': 10.5},
      {'generation': '10'},
      {'generation': true},
      {'reason': 10},
    ];
    for (final status in [
      'accepted',
      'active',
      'committed',
      'alreadyCommitted',
      'invalidated',
      'revoked',
    ]) {
      for (final corruption in corruptions) {
        final result = BleG2OtaTransactionResult.fromNative({
          ...identity,
          'status': status,
          ...corruption,
        });
        expect(result.status, BleG2OtaTransactionStatus.unknown,
            reason: '$status / $corruption');
        expect(result.isRetired, isFalse);
      }
    }
  });

  test('missing or unrecognized wire result fails closed without throwing', () {
    for (final value in <Object?>[
      null,
      false,
      1,
      'committed',
      const [],
      const {},
      {...identity, 'status': 'newUnknownStatus'},
      {...identity, 'status': true},
    ]) {
      final result = BleG2OtaTransactionResult.fromNative(value);
      expect(result.status, BleG2OtaTransactionStatus.unknown);
      expect(result.isRetired, isFalse);
    }
  });

  test('directly constructed malformed result cannot prove retirement', () {
    const result = BleG2OtaTransactionResult(
      status: BleG2OtaTransactionStatus.committed,
      transactionId: '',
      generation: 0,
      instanceId: '',
    );
    expect(result.isRetired, isFalse);
    expect(
      const BleG2OtaContext(
        transactionId: ' ',
        generation: 10,
        instanceId: 'native-instance',
      ).isValid,
      isFalse,
    );
  });
}
