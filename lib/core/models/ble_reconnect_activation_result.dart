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
  });

  final String belongConfig;
  final String uuid;
  final String name;
  final BleReconnectActivationState state;
  final String reason;

  /// 只有 resolved / identityPending 才代表 native 真正持有长期回连 owner。
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
    );
  }
}
