/// Exact business-auth attempt token passed from `connectFinish` handling back
/// to native before the app sends post-GATT authentication commands.
class BleBusinessConnectionAttempt {
  const BleBusinessConnectionAttempt({
    required this.uuid,
    required this.sessionGeneration,
    required this.attemptGeneration,
  });

  /// Native endpoint id from the `connectStatus` event.
  final String uuid;

  /// Dart recovery batch generation; this stays stable across a logical batch.
  final int sessionGeneration;

  /// Native GATT/admission attempt generation; this rejects stale callbacks.
  final int attemptGeneration;

  /// MethodChannel payload kept intentionally flat for Kotlin/Swift parity.
  Map<String, Object?> toJson() => <String, Object?>{
        'uuid': uuid,
        'sessionGeneration': sessionGeneration,
        'attemptGeneration': attemptGeneration,
      };
}

/// Result of an exact business connection prepare/commit operation.
enum BleBusinessConnectionStatus {
  accepted,
  invalidArguments,
  missingAdmission,
  attemptMismatch,
  missingPrepare,
  deviceDisconnected,
  gattNotReady,
}

BleBusinessConnectionStatus bleBusinessConnectionStatusFromNative(
  Object? value,
) {
  final name = value?.toString();
  return BleBusinessConnectionStatus.values.firstWhere(
    (status) => status.name == name,
    orElse: () => BleBusinessConnectionStatus.invalidArguments,
  );
}
