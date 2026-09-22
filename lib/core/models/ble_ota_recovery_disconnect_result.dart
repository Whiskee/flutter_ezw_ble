/// Native 对 OTA 写阻塞 recovery teardown 的接收结果。
///
/// 该枚举只表达 native 是否接受 exact endpoint/session/attempt 断开请求；
/// 上层是否继续恢复还要再等待真实断连事件和自身 OTA generation/budget。
enum BleOtaRecoveryDisconnectResult {
  accepted,
  alreadyDisconnected,
  staleIdentity,
  unavailable,
}

/// 将 MethodChannel 返回的字符串收口为 fail-closed 枚举。
///
/// native 新旧版本不一致或返回未知值时必须走 [unavailable]，避免 Dart 在没有
/// exact teardown 承诺的情况下继续复用 OTA recovery 链。
BleOtaRecoveryDisconnectResult bleOtaRecoveryDisconnectResultFromNative(
  String? raw,
) {
  return BleOtaRecoveryDisconnectResult.values.firstWhere(
    (status) => status.name == raw,
    orElse: () => BleOtaRecoveryDisconnectResult.unavailable,
  );
}
