import 'package:json_annotation/json_annotation.dart';

part 'ble_native_connection_trace.g.dart';

/// Snapshot of the current native physical BLE attempt.
///
/// The trace is intentionally process-local and optional. Older native payloads
/// omit it, and newer native code only emits it when the host enables the
/// host Analytics total gate.
@JsonSerializable(explicitToJson: true)
class BleNativeConnectionTrace {
  const BleNativeConnectionTrace({
    required this.attemptId,
    required this.steps,
    this.capturedElapsedMs,
    this.lastRssiDbm,
    this.rssiAgeMs,
    this.phy,
    this.requestedPriority,
  });

  /// Native UUID generated for one real physical GATT/CoreBluetooth attempt.
  final String attemptId;

  /// Ordered native connection stages, capped by the platform trace buffer.
  final List<BleNativeConnectionTraceStep> steps;

  /// Native monotonic elapsed time when this snapshot was captured.
  final int? capturedElapsedMs;

  /// Latest RSSI sample in dBm. Missing when the OS never delivered a sample.
  final int? lastRssiDbm;

  /// Age of [lastRssiDbm] relative to the native snapshot time.
  final int? rssiAgeMs;

  /// Platform-reported PHY label, for example `1M`, `2M`, `CODED`, or null.
  final String? phy;

  /// Last connection-priority preference requested by Android native code.
  final String? requestedPriority;

  factory BleNativeConnectionTrace.fromJson(Map<String, dynamic> json) =>
      _$BleNativeConnectionTraceFromJson(json);

  Map<String, dynamic> toJson() => _$BleNativeConnectionTraceToJson(this);
}

/// One native stage inside a physical BLE attempt trace.
@JsonSerializable()
class BleNativeConnectionTraceStep {
  const BleNativeConnectionTraceStep({
    required this.stepSeq,
    required this.stage,
    required this.result,
    required this.elapsedMs,
    this.serviceType,
    this.causeDomain,
    this.causeCode,
    this.droppedCount,
    this.bondState,
    this.writeLimitBytes,
    this.linkTrigger,
    this.rssiBucket,
    this.phy,
    this.priorityAction,
    this.actionResult,
  });

  /// Monotonic per-attempt sequence. Native buffers never reuse a sequence.
  final int stepSeq;

  /// Stable stage key, such as `scan`, `connect`, `service_discovery`.
  final String stage;

  /// Stage result key, such as `started`, `success`, `failed`, `gap`.
  final String result;

  /// Elapsed milliseconds since native created the physical attempt trace.
  final int elapsedMs;

  /// Optional private service type for service/characteristic/CCCD details.
  final String? serviceType;

  /// Raw platform domain, e.g. `GATT`, `HCI`, `CoreBluetooth`, `CBATTError`.
  final String? causeDomain;

  /// Raw platform status/error code. Null means native had no reliable code.
  final int? causeCode;

  /// Number of native steps omitted before this gap marker.
  final int? droppedCount;

  /// Public platform bond evidence. iOS only emits `not_observable` or
  /// `security_recovery`; it never claims that the peripheral is bonded.
  final String? bondState;

  /// Public ATT payload limit when the platform exposes it without guessing MTU.
  final int? writeLimitBytes;

  /// Stable trigger for a low-frequency adaptive-link state transition.
  final String? linkTrigger;

  /// Coarse RSSI bucket; raw samples remain in the attempt diagnostic snapshot.
  final String? rssiBucket;

  /// Controller-reported or requested PHY label for a link-policy transition.
  final String? phy;

  /// Requested connection-priority action, for example `HIGH` or `BALANCED`.
  final String? priorityAction;

  /// Synchronous platform acceptance result; it does not claim controller apply.
  final String? actionResult;

  factory BleNativeConnectionTraceStep.fromJson(Map<String, dynamic> json) =>
      _$BleNativeConnectionTraceStepFromJson(json);

  Map<String, dynamic> toJson() => _$BleNativeConnectionTraceStepToJson(this);
}
