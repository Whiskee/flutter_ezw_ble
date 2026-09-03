/// Native scanner start outcome.
///
/// A positive [generation] identifies the exact native scan window. Android
/// reuses it for a later `onScanFailed` event so Dart can reject stale errors.
class BleScanStartResult {
  const BleScanStartResult({
    required this.started,
    required this.generation,
    required this.reason,
    this.errorCode,
  });

  /// Whether the platform confirmed that its scanner is running.
  final bool started;

  /// Monotonic native scan identity; zero means no scan window was created.
  final int generation;

  /// Stable machine-readable reason for logging and recovery decisions.
  final String reason;

  /// Android `ScanCallback` error code when an async start fails.
  final int? errorCode;

  /// Parses the platform-channel payload without treating malformed data as a
  /// successful scan.
  factory BleScanStartResult.fromNative(Object? value) {
    final map = value is Map ? value : const <Object?, Object?>{};
    return BleScanStartResult(
      started: map['started'] == true,
      generation: (map['generation'] as num?)?.toInt() ?? 0,
      reason: map['reason'] as String? ?? 'invalidResult',
      errorCode: (map['errorCode'] as num?)?.toInt(),
    );
  }
}
