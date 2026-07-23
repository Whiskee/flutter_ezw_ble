import 'package:flutter_ezw_ble/core/models/ble_connect_source.dart';

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

  /// even_connect recovery batch 的逻辑代次；不得与 native Gate attempt 混用。
  final int sessionGeneration;

  /// Native 在 activation 期间通过 State Restoration/系统连接找回的平台 UUID。
  ///
  /// [uuid] 必须继续保留 Dart 请求身份供 recovery batch 对账；因此平台身份迁移
  /// 使用独立字段返回，不能在 MethodChannel 回执中直接覆盖 [uuid]。
  final String resolvedUuid;

  /// 平台身份的解析来源，例如 `stateRestoration` 或 `systemConnected`。
  final String resolutionSource;

  /// 除 rejected 外都表示 native 已保留当前连接 owner。
  bool get isAccepted => state != BleReconnectActivationState.rejected;

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
