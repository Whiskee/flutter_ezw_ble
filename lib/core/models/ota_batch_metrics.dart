/// One native OTA batch completion. It does not prove delivery to firmware.
class OtaBatchMetrics {
  const OtaBatchMetrics({
    required this.elapsedMs,
    required this.packetCount,
    required this.wireBytes,
    required this.completionKind,
    this.writeLimitBytes,
    this.mtu,
    this.requestedPhy,
    this.actualPhy,
    this.lastRssiDbm,
    this.rssiAgeMs,
    this.nativeQueueBackpressureCount,
    this.nativeQueueBackpressureWaitMs,
    this.nativeQueueSoftThrottleCount,
    this.nativeQueueSoftThrottleWaitMs,
    this.nativeQueueRetryTimerLateMs,
    this.nativeQueuePollResumeCount,
    this.nativeQueueCallbackResumeCount,
    this.nativeAckToNextFileMs,
    this.nativeNotifyToCreditMs,
  });

  final int elapsedMs;
  final int packetCount;
  final int wireBytes;
  final String completionKind;

  /// ATT payload limit frozen from the already-known native link snapshot.
  ///
  /// A null value means the platform did not expose a reliable value for this
  /// batch; callers must keep it as unknown rather than treating it as zero.
  final int? writeLimitBytes;

  /// Negotiated ATT MTU when the platform already has it cached.
  final int? mtu;

  /// Last host-side requested PHY, when observable without issuing a new read.
  final String? requestedPhy;

  /// Last controller-reported PHY, when observable without issuing a new read.
  final String? actualPhy;

  /// Last native RSSI sample already cached on the active connection attempt.
  final int? lastRssiDbm;

  /// Age of [lastRssiDbm] in milliseconds, if the native trace exposes it.
  final int? rssiAgeMs;

  /// Number of native queue backpressure episodes observed while submitting the batch.
  final int? nativeQueueBackpressureCount;

  /// Total native queue backpressure wait duration for this batch, in milliseconds.
  final int? nativeQueueBackpressureWaitMs;

  /// Number of native soft-throttle yields hit by this batch.
  final int? nativeQueueSoftThrottleCount;

  /// Monotonic queue waits, not radio transmission or firmware processing time.
  final int? nativeQueueSoftThrottleWaitMs;
  final int? nativeQueueRetryTimerLateMs;
  final int? nativeQueuePollResumeCount;
  final int? nativeQueueCallbackResumeCount;

  /// Same-native-clock receipt-to-next-FILE/credit timing; null if unobserved.
  final int? nativeAckToNextFileMs;
  final int? nativeNotifyToCreditMs;

  static OtaBatchMetrics? fromNative(Object? value) {
    if (value is! Map) return null;
    final elapsedMs = value['elapsedMs'];
    final packetCount = value['packetCount'];
    final wireBytes = value['wireBytes'];
    final completionKind = value['completionKind'];
    if (elapsedMs is! int ||
        packetCount is! int ||
        wireBytes is! int ||
        completionKind is! String) {
      return null;
    }
    return OtaBatchMetrics(
      elapsedMs: elapsedMs,
      packetCount: packetCount,
      wireBytes: wireBytes,
      completionKind: completionKind,
      writeLimitBytes: _optionalInt(value['writeLimitBytes']),
      mtu: _optionalInt(value['mtu']),
      requestedPhy: _optionalString(value['requestedPhy']),
      actualPhy: _optionalString(value['actualPhy']),
      lastRssiDbm: _optionalInt(value['lastRssiDbm']),
      rssiAgeMs: _optionalInt(value['rssiAgeMs']),
      nativeQueueBackpressureCount:
          _optionalInt(value['nativeQueueBackpressureCount']),
      nativeQueueBackpressureWaitMs:
          _optionalInt(value['nativeQueueBackpressureWaitMs']),
      nativeQueueSoftThrottleCount:
          _optionalInt(value['nativeQueueSoftThrottleCount']),
      nativeQueueSoftThrottleWaitMs:
          _optionalInt(value['nativeQueueSoftThrottleWaitMs']),
      nativeQueueRetryTimerLateMs:
          _optionalInt(value['nativeQueueRetryTimerLateMs']),
      nativeQueuePollResumeCount:
          _optionalInt(value['nativeQueuePollResumeCount']),
      nativeQueueCallbackResumeCount:
          _optionalInt(value['nativeQueueCallbackResumeCount']),
      nativeAckToNextFileMs: _optionalInt(value['nativeAckToNextFileMs']),
      nativeNotifyToCreditMs: _optionalInt(value['nativeNotifyToCreditMs']),
    );
  }

  static int? _optionalInt(Object? value) => value is int ? value : null;

  static String? _optionalString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}
