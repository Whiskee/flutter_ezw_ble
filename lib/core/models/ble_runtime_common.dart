/// Exact native business owner, queried without scanning or changing BLE state.
/// Both generations must be positive; a cached UUID alone cannot pause a link.
class BleRuntimeCommonOwner {
  const BleRuntimeCommonOwner({
    required this.uuid,
    required this.sessionGeneration,
    required this.attemptGeneration,
  });

  final String uuid;
  final int sessionGeneration;
  final int attemptGeneration;

  static BleRuntimeCommonOwner? fromNative(Object? raw) {
    if (raw is! Map) return null;
    final uuid = raw['uuid'];
    final session = raw['sessionGeneration'];
    final attempt = raw['attemptGeneration'];
    if (uuid is! String ||
        uuid.isEmpty ||
        session is! int ||
        session <= 0 ||
        attempt is! int ||
        attempt <= 0) {
      return null;
    }
    return BleRuntimeCommonOwner(
      uuid: uuid,
      sessionGeneration: session,
      attemptGeneration: attempt,
    );
  }
}

/// Runtime CCCD confirmation is distinct from a method invocation succeeding.
enum BleRuntimeCommonStatus {
  confirmed,
  stale,
  notConnected,
  busy,
  failed,
  unknown,
  reconnecting,
  unavailable,
}

class BleRuntimeCommonResult {
  const BleRuntimeCommonResult({
    required this.status,
    this.enabled,
    this.revision = 0,
  });

  final BleRuntimeCommonStatus status;
  final bool? enabled;
  final int revision;
  bool get isConfirmed => status == BleRuntimeCommonStatus.confirmed;

  factory BleRuntimeCommonResult.fromNative(Object? raw) {
    final data = raw is Map ? raw : const <Object?, Object?>{};
    return BleRuntimeCommonResult(
      status: BleRuntimeCommonStatus.values.firstWhere(
        (value) => value.name == data['status'],
        orElse: () => BleRuntimeCommonStatus.unavailable,
      ),
      enabled: data['enabled'] is bool ? data['enabled'] as bool : null,
      revision: data['revision'] is int ? data['revision'] as int : 0,
    );
  }
}
