/// 一次连接状态事件的触发来源。
///
/// `unknown` 保留给旧版原生 payload 和普通首连，避免新增字段破坏历史调用方。
enum BleConnectSource {
  unknown,
  autoReconnect,
  manualReconnect,
  stateRestoration,
  foreground,
}
