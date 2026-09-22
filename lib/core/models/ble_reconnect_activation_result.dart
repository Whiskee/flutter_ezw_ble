import 'package:flutter_ezw_ble/core/models/ble_connect_source.dart';

/// Native activation 的调用语义。
///
/// `initial` 用于冷启动/蓝牙恢复的首次提交，`reconcile` 用于上层复用
/// recovery batch 时重新确认 native owner，`promotion` 用于手动点击提升
/// 已存在的 pending owner。未知 native/host 值必须 fail closed。
enum BleReconnectActivationMode {
  initial,
  reconcile,
  promotion,
  unknown;

  static BleReconnectActivationMode fromNative(Object? value) {
    return BleReconnectActivationMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => BleReconnectActivationMode.unknown,
    );
  }
}

/// Native owner 对账处置结果。
///
/// 上层必须读这个字段确认 native 当前是否真的持有 owner；旧的 `state`
/// 只保留稳定 UUID / identity pending / rejected 的兼容状态。
enum BleReconnectOwnerDisposition {
  created,
  reused,
  repaired,
  deferred,
  rejected;

  static BleReconnectOwnerDisposition fromNative(Object? value) {
    return BleReconnectOwnerDisposition.values.firstWhere(
      (disposition) => disposition.name == value,
      orElse: () => BleReconnectOwnerDisposition.rejected,
    );
  }
}

/// Native 接受自动回连目标后的 owner 状态。
///
/// `resolved` 表示目标已有稳定平台身份并已交给长期回连；`identityPending`
/// 表示 iOS 已持有名称身份 owner，等待扫描补齐 `CBPeripheral.identifier`；
/// `rejected` 表示 native 没有建立任何 owner，上层不得复用为“正在回连”。
enum BleReconnectActivationState {
  resolved,
  identityPending,
  rejected;

  /// 未知 native 值按拒绝处理，避免新旧版本契约不一致时产生假 owner。
  static BleReconnectActivationState fromNative(Object? value) {
    return BleReconnectActivationState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => BleReconnectActivationState.rejected,
    );
  }
}

/// 单个自动回连目标的 native 激活回执。
class BleReconnectActivationResult {
  const BleReconnectActivationResult({
    required this.belongConfig,
    required this.uuid,
    required this.name,
    required this.state,
    required this.reason,
    this.source = BleConnectSource.unknown,
    this.mode = BleReconnectActivationMode.initial,
    this.ownerDisposition = BleReconnectOwnerDisposition.rejected,
    this.sessionGeneration = 0,
    this.resolvedUuid = '',
    this.resolutionSource = '',
  });

  final String belongConfig;
  final String uuid;
  final String name;
  final BleReconnectActivationState state;
  final String reason;
  final BleConnectSource source;
  final BleReconnectActivationMode mode;
  final BleReconnectOwnerDisposition ownerDisposition;

  /// even_connect recovery batch 的逻辑代次；不得与 native Gate attempt 混用。
  final int sessionGeneration;

  /// Native 在 activation 期间通过系统连接或进程内缓存找回的平台 UUID。
  ///
  /// [uuid] 必须继续保留 Dart 请求身份供 recovery batch 对账；因此平台身份迁移
  /// 使用独立字段返回，不能在 MethodChannel 回执中直接覆盖 [uuid]。
  final String resolvedUuid;

  /// 平台身份的解析来源，例如 `systemConnected` 或 `cache`。
  final String resolutionSource;

  /// 只有兼容 state 与实时 owner disposition 都接受时才算 native 已持有 owner。
  bool get isAccepted =>
      state != BleReconnectActivationState.rejected &&
      mode != BleReconnectActivationMode.unknown &&
      ownerDisposition != BleReconnectOwnerDisposition.rejected;

  /// 宽松解析 MethodChannel map，同时对缺失/未来状态采取 fail-closed。
  factory BleReconnectActivationResult.fromNative(Object? value) {
    final map = value is Map ? value : const <Object?, Object?>{};
    return BleReconnectActivationResult(
      belongConfig: map['belongConfig'] as String? ?? '',
      uuid: map['uuid'] as String? ?? '',
      name: map['name'] as String? ?? '',
      state: BleReconnectActivationState.fromNative(map['state']),
      reason: map['reason'] as String? ?? 'invalidNativeAck',
      source: BleConnectSource.values.firstWhere(
        (source) => source.name == map['source'],
        orElse: () => BleConnectSource.unknown,
      ),
      mode: BleReconnectActivationMode.fromNative(map['mode']),
      ownerDisposition: BleReconnectOwnerDisposition.fromNative(
        map['ownerDisposition'],
      ),
      sessionGeneration: switch (map['sessionGeneration']) {
        final int value => value,
        final num value => value.toInt(),
        _ => 0,
      },
      resolvedUuid: map['resolvedUuid'] as String? ?? '',
      resolutionSource: map['resolutionSource'] as String? ?? '',
    );
  }
}
