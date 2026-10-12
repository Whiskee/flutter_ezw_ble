# iOS 原生 Debug 日志门控验证

2026-10-08。本地分支 `codex/fix/ios-native-debug-log-gate`，基线
`d8f546bea55789cc3670d73a7f2dba6e348ca207`，未提交或推送。

本次在原生日志生产处避免关闭 Debug 时的插值和 EventChannel 发出。新增
`EzwBle.to.setDebugLoggingEnabled(bool)`，iOS 每进程默认关闭；Android 接受 no-op。
setter 只写独立静态 policy，不构造 BLE manager/central，不改 SR、owner、重试、
连接状态 JSON、通知 payload、恢复事件账本或 Trace。启动直接日志、扫描诊断预处理
和 OTA String 回调都在求值前门控。Error 保留，服务发现错误和 OTA 硬背压/外设释放
失败使用 Error；主动取消仍为 Debug。

## 生产入口与历史边界

高频路径为 `CBPeripheralDelegate.didUpdateValueFor` → `BleManager.loggerD`，
以及 `sendCmd/sendCmdNoWait` → logger / `OtaWriteQueue.enqueue/pump`。
原实现接收已经构造的 `String`，日志是否最终落盘不影响插值和跨 Flutter channel 的
前置成本。关闭 Debug 的宿主过滤无法阻止源头的这部分工作。

`loggerD(msg: String)` 方法结构见提交
`06c02661e7c0f63c5e86d565d94af114ecfd6b9c`，父提交
`38c14ac0ad5ad332a1f6b14c7e599f64575a0ca2`。标题
`feat(ble): add reset functionality to BleManager and update method signatures for disconnectDevice`。
Author 和 committer 均为 `Whiskee <whiskee.chen@evenrealities.com>`，两时间均为
`2025-08-14T21:33:19+08:00`。父子 diff 同时显示此前已有 `logger?("[d]-...\(data.hexString())")`
String 回调，因此这次封装提交不是已证实的性能缺陷最初引入。更早最初引入尚未确定，
也没有人员责任证据。这条日志开销在 2.3.0/2.3.1 的原生源码中已存在；本次修复不能
据此证明 2.3.1 耗电增量的根因。

## 自动化结果

使用仓库 FVM Flutter 3.32.0 / Dart 3.8.0：

- `fvm flutter test --no-pub --reporter expanded`：**180 项通过**。
- 改动 Dart API 与测试的定向 `fvm flutter analyze --no-pub ...`：无问题。
- `git diff --check`：通过。
- 原生行为测试由 Dart runner 调用 `xcrun swiftc -O`：编译生产 policy、直接取自
  Manager/扫描文件的真实方法和去重器，以及完整生产 OTA 队列。仅替换 Flutter
  Result/Error/事件接收边界，保留 CoreBluetooth 模块和 OTA 实码。

同一个优化模式 harness 的负证命令：

```sh
EZW_BLE_LOG_BASELINE=d8f546bea55789cc3670d73a7f2dba6e348ca207 fvm flutter test --no-pub test/ios_debug_logging_test.dart --plain-name 'optimized native logging and real OTA queue preserve behavior' --reporter expanded
```

该选项只让测试编译原基线的真实 `loggerD/loggerE` 声明，不改生产文件。负证输出：
`disabled notify samples=50000 formatted=50000 emitted=50000`，行为断言失败。
当前实现输出：`disabled notify samples=50000 formatted=0 emitted=0`。
原负证记录在本工作目录 `.dart_tool/native-debug-log-before.txt`。

关闭时另有 256 笔 OTA 队列实际提交与完成全部通过，`diagnosticReads=0`。
开启时保留原日志格式，运行中关闭立即阻止下一次日志构造；扫描关闭时不消耗去重
键，开启后首次断点仍输出。Error 在关闭时可用，15 秒硬背压仍产生一次
`ota_write_stalled` 并保留 session 7 / attempt 9，外设释放仍返回
`ota_write_unavailable`。这些测试验证日志构造和队列不变量，不是功耗测试。

## 未覆盖

未在本插件任务中完成完整 iPhoneOS 宿主构建、Android 原生构建或真机运行。
MAC 优化编译与 Flutter 回归不能替代设备上的 BLE/SR、音频、OTA 验收。实际 CPU、
唤醒次数、SQLite、日志写盘与整机电量收益尚未测量；不能报告节电比例。
