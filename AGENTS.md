# AGENTS.md

本文是代理在 `flutter_ezw_ble` 仓库工作的操作指南。修改代码前必须先阅读 `ARCHITECTURE.md`。

## 项目定位

`flutter_ezw_ble` 是配置驱动的 Flutter BLE 插件。Dart 侧定义 `BleConfig` 扫描/GATT 规则并暴露 MethodChannel / EventChannel API；Android 和 iOS 原生侧执行扫描、连接、GATT 写入、OTA 写入策略和事件回传。

优先阅读：

- `ARCHITECTURE.md`：插件契约、MethodChannel/EventChannel API、模型、原生职责和扩展规则。
- `docs/AUTO_RECONNECT_SPEC.md`：改自动回连、长期 reconnect intent、GATT readiness gate 前必须阅读。
- `docs/IOS_STATE_RESTORATION_SPEC.md`：改 iOS CoreBluetooth State Preservation / Restoration 前必须阅读。
- `docs/IOS_OTA_NOWAIT_SPEC.md`：改 iOS OTA `WriteWithoutResponse` 行为前必须阅读。
- `docs/ble/BLE_ISSUE_PLAYBOOK.md`：排查扫描、连接、重连、State Restoration 和 example 启动问题时优先查看。
- `README.md`：排障说明和 HCI 错误码参考。

## 关键边界

- `lib/flutter_ezw_ble.dart` 拥有 `EzwBle` 单例，并把 EventChannel stream 映射为 Dart 类型模型。
- `lib/flutter_ezw_ble_method_channel.dart` 是 Dart MethodChannel 实现。
- `lib/flutter_ezw_ble_platform_interface.dart` 定义平台 API 契约。
- `lib/flutter_ezw_ble_event_channel.dart` 定义 EventChannel 名称和缓存的 broadcast stream。
- `lib/core/models/**` 是 JSON 序列化的 BLE 配置、设备、扫描、连接、状态和命令模型。
- `android/src/main/kotlin/com/fzfstudio/ezw_ble/**` 是 Android BluetoothGatt 实现。
- `ios/Classes/**` 是 iOS CoreBluetooth 实现，包含 `BleManager`、`BleChannel` 和 `OtaWriteQueue`。
- 原生自动回连只在业务调用 `deviceConnected(uuid)` 后启用；`connectFinish` 只表示 GATT ready，不表示业务 connected。
- `timeout`、`noDeviceFound`、`serviceFail`、`charsFail` 是单次尝试失败，不是长期回连停止条件；只有用户/业务主动断连、移除、reset、清缓存、配置关闭或插件释放才能取消 reconnect intent。
- iOS State Restoration 只能恢复进程内 BLE 工作和 CoreBluetooth peripheral；私有服务、notify/CCCD、业务认证指令必须重新执行，不承诺把 App UI 拉到前台。
- iOS `CBCentralManager(queue: nil)` 的 `retrieveConnectedPeripherals` / `retrievePeripherals` 只允许经 active 生命周期门禁调用；inactive/background/terminating 时只能复用 restoration/内存 peripheral，缺失时保留 exact deferred owner，不得制造 `noDeviceFound` 或增加 retry。`didBecomeActive` 补偿必须复验 config、owner 和 session generation。
- iOS 业务 `connected` 释放 Gate 前必须把已接受的 `sessionGeneration + attemptGeneration` 成对保存在 reconnect owner；随后的 CoreBluetooth `didDisconnect` / 蓝牙关闭终态必须回传该 exact pair。禁止只恢复 session 而把 attempt 降为 0，显式取消、替换、移除 owner 必须同时使该快照不可达。
- Android/iOS G2 `securityGate`（5403）必须在普通业务 Notify 订阅和 `connectFinish` 前完成一次有响应保护写。Android G2 必须配置 `initiateBinding=true`：exact admission 先通过 `createBond()` 唯一拉起系统配对，Bond 完成后再发现服务并写 5403 验证当前链路密钥，避免主动 Bond 与受保护写分别触发配对弹窗；已 Bond 设备不得重复 `createBond()`，5403 缺失/不支持时按旧固件路径继续普通 readiness。真实 Gate/Bond 安全失败按每 endpoint 每 episode 最多 5 次恢复，第 5 次发布静默 `securityRecoveryExhausted`；手动第一次安全失败仍走 `boundFail`。
- iOS R1 自动回连首次收到 CoreBluetooth Code 14 后，只能使用新广告中的真实 `CBPeripheral` 恢复：App active 且蓝牙可用时按 10 秒扫描、5 秒静默等待无限循环，扫描 miss 不得删除 owner、发送 Dart 终态或制造 attempt 0；新 peripheral 再次 Code 14 才停止自动 owner并保持静默。手动点击必须 exact 接管并使用独立正 generation，只有当前手动物理 attempt 的真实 Code 14 才能上报 `alreadyBound`；生命周期暂停、共享扫描和迟到 callback 不得跨 owner 生效。

## 修改规则

- 默认注释策略：任何代码改动都必须同步补充必要注释。新增/重构的类、状态字段、函数、跨异步流程和平台桥接逻辑必须写清楚“为什么这样做”和“关键流程顺序”；不要等用户再次提醒才补注释。
- 新增 MethodChannel 方法时，同步更新 platform interface、Dart method-channel 实现、Android 分发/实现、iOS 分发/实现和测试。
- 新增 EventChannel 时，同步更新枚举、Dart stream 映射和两个平台的事件源。
- `ezwBleTag` 和 channel name 拼接规则必须与原生常量保持一致。
- `initConfigs` 必须使用 `customToJson` 序列化嵌套模型，不要改成浅层 JSON。
- 不要手工编辑 `*.g.dart`。修改源模型后运行 build_runner。
- `receiveData` 的二进制 payload 跨 Method/EventChannel 时保持 Base64 约定。
- Android `onConnectionStateChange` 的 status 使用 HCI/controller 断连语义；characteristic/descriptor 回调才使用 ATT/GATT 操作语义。数值 `8` 在前者是连接超时，严禁触发授权恢复/cache refresh/`needsScanBeforeConnect`；在后者是授权不足，必须走授权恢复后再按回调阶段终止。
- iOS OTA 中 `psType == 1` 的 `sendCmdNoWait` 必须与 `OtaWriteQueue`、`canSendWriteWithoutResponse` 和 `docs/IOS_OTA_NOWAIT_SPEC.md` 对齐。
- `sendOtaPacketBatch` 只接受 already-framed OTA 小包；Future 等最后一包提交成功，Android 禁止并发 GATT write，失败必须丢掉剩余包。
- `sendFilePacketBatch`（`psType=3`）与 OTA 批次共用队列实现但**实例必须独立**：`quiteUpgradeState` 只能取消 OTA attempt，共用 pending 会打断进行中的文件传输；升级态仍 fail closed 拒绝文件批次。Android 三条发送路径（普通队列 / OTA 批次 / 文件批次）共用 GATT 单槽位，回调归属只能由 `BleGattWriteCallbackOwnerPolicy` 判定，普通队列在任一批次占槽时不得写出；物理 session 失效与整机 teardown 必须同时释放两条批次通道的 Dart await。typed error code 按通道前缀区分（`ota_write_*` / `file_write_*`），不得混用。
- Android GATT ready 与进入 OTA 后必须请求 LE 2M PHY（`setPreferredPhy`）；`connectGatt` 的 `PHY_LE_2M` hint 不能当成已切到 2M。PHY 失败不得阻断连接或传输。iOS 无公开 PHY API，只记日志。
- 改 auto reconnect 或 iOS State Restoration 时，同步更新 `docs/AUTO_RECONNECT_SPEC.md`、`docs/IOS_STATE_RESTORATION_SPEC.md`、`ARCHITECTURE.md` 和相关测试/排障记录。
- BLE 行为变化通常需要同时审视 Dart 和原生两端，不要假设 Android 与 iOS 可以共享实现细节。

## 常用命令

- `flutter analyze`：静态分析。
- `flutter test`：运行插件测试。
- `dart format lib test`：格式化 Dart 源码。
- `dart run build_runner build --delete-conflicting-outputs`：重新生成 JSON 模型输出。

使用仓库指定的 Flutter/FVM 版本。声明 channel、模型或原生 BLE 改动完成前运行最窄的相关测试；涉及共享 BLE 行为时运行 `flutter test`。
