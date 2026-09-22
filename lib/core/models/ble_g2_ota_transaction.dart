/// Endpoint identity frozen by even_connect before a G2 OTA transaction starts.
///
/// The logical endpoint set belongs to the transaction. The physical
/// session/attempt pair is only used for writes and detach operations when it
/// is positive; native finish must still be able to retire the endpoint after
/// the GATT object has already gone away.
class BleG2OtaEndpointIdentity {
  const BleG2OtaEndpointIdentity({
    required this.uuid,
    this.name = '',
    this.sessionGeneration = 0,
    this.attemptGeneration = 0,
  });

  final String uuid;
  final String name;
  final int sessionGeneration;
  final int attemptGeneration;

  Map<String, Object?> toJson() => <String, Object?>{
        'uuid': uuid,
        'name': name,
        'sessionGeneration': sessionGeneration,
        'attemptGeneration': attemptGeneration,
      };
}

/// Native-owned G2 OTA endpoint state transition.
enum BleG2OtaEndpointAction {
  bind,
  recover,
  park,
}

/// Explicit OTA transaction context forwarded on native-owned calls.
class BleG2OtaContext {
  const BleG2OtaContext({
    required this.transactionId,
    required this.generation,
    required this.instanceId,
  });

  final String transactionId;
  final int generation;
  final String instanceId;

  Map<String, Object?> toJson() => <String, Object?>{
        'transactionId': transactionId,
        'generation': generation,
        'instanceId': instanceId,
      };

  bool get isValid =>
      transactionId.trim().isNotEmpty &&
      generation > 0 &&
      instanceId.trim().isNotEmpty;

  /// Existing send/activation calls receive OTA credentials as a nested map;
  /// flat ota* keys are reserved for native receiveData events.
  Map<String, Object?> toMethodArguments() => <String, Object?>{
        'otaContext': toJson(),
      };
}

/// Native transaction result states.
///
/// Only [committed] and [alreadyCommitted] prove full local retirement. Unknown
/// or missing native replies intentionally map to [unknown] so callers fail
/// closed instead of treating old plugins as success.
enum BleG2OtaTransactionStatus {
  accepted,
  committed,
  alreadyCommitted,
  active,
  staleOwner,
  invalidRequest,
  unavailable,
  unknown,
  invalidated,
  revoked;

  static BleG2OtaTransactionStatus fromNative(Object? value) {
    return BleG2OtaTransactionStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => BleG2OtaTransactionStatus.unknown,
    );
  }
}

class BleG2OtaTransactionResult {
  const BleG2OtaTransactionResult({
    required this.status,
    required this.transactionId,
    required this.generation,
    required this.instanceId,
    this.reason = '',
  });

  final BleG2OtaTransactionStatus status;
  final String transactionId;
  final int generation;
  final String instanceId;
  final String reason;

  /// Also validate direct constructions: a typed enum alone is not a native
  /// retirement receipt. Callers must additionally match their frozen owner.
  bool get isRetired =>
      transactionId.trim().isNotEmpty &&
      generation > 0 &&
      instanceId.trim().isNotEmpty &&
      (status == BleG2OtaTransactionStatus.committed ||
          status == BleG2OtaTransactionStatus.alreadyCommitted);

  factory BleG2OtaTransactionResult.fromNative(Object? value) {
    final map = value is Map ? value : const <Object?, Object?>{};
    final parsedStatus = BleG2OtaTransactionStatus.fromNative(map['status']);
    final transactionId = map['transactionId'];
    final generation = map['generation'];
    final instanceId = map['instanceId'];
    final reason = map['reason'];
    final parsedTransactionId = transactionId is String ? transactionId : '';
    final parsedGeneration = switch (generation) {
      final int value => value,
      _ => 0,
    };
    final parsedInstanceId = instanceId is String ? instanceId : '';
    final hasNativeIdentity = parsedTransactionId.trim().isNotEmpty &&
        parsedGeneration > 0 &&
        parsedInstanceId.trim().isNotEmpty;
    // Unknown field types cannot turn into permission to write, retire, or
    // release an invalidated owner. Preserve IDs verbatim for exact matching.
    final hasValidReason = reason == null || reason is String;
    final status = switch (parsedStatus) {
      BleG2OtaTransactionStatus.accepted ||
      BleG2OtaTransactionStatus.committed ||
      BleG2OtaTransactionStatus.alreadyCommitted ||
      BleG2OtaTransactionStatus.active ||
      BleG2OtaTransactionStatus.invalidated ||
      BleG2OtaTransactionStatus.revoked =>
        hasNativeIdentity && hasValidReason
            ? parsedStatus
            : BleG2OtaTransactionStatus.unknown,
      _ => parsedStatus,
    };
    return BleG2OtaTransactionResult(
      status: status,
      transactionId: parsedTransactionId,
      generation: parsedGeneration,
      instanceId: parsedInstanceId,
      reason: reason is String ? reason : '',
    );
  }
}
