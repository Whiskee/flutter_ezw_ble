# iOS CoreBluetooth State Restoration Spec

本文定义 `flutter_ezw_ble` 在 iOS 侧落地 CoreBluetooth State Preservation / Restoration 的工程契约。它是 `docs/AUTO_RECONNECT_SPEC.md` 的 iOS 专项补充，重点回答三个问题：

- App 被系统挂起或回收后，CoreBluetooth 能恢复到什么程度；
- 原生层如何把 restored peripheral 重新接回统一 GATT pipeline；
- Dart / even_connect 在恢复后必须重新执行哪些业务步骤。

## 1. 能力边界

iOS State Restoration 的目标是恢复 BLE 进程内工作，不是把 App 拉到前台。

可以做到：

- 系统在合适的 CoreBluetooth 事件到来时恢复 App 进程；
- `centralManager(_:willRestoreState:)` 收到系统保存的 peripheral；
- 原生层在 `initConfigs` 完成后继续 pending connect 或复用已连接 peripheral；
- 重新执行 service discovery、characteristic discovery、notify / CCCD 注册；
- GATT ready 后上报 `connectFinish`，等待 Dart 业务重新鉴权。

不能承诺：

- 把 App UI 自动切到前台；
- 绕过用户显式强制退出后的系统限制；
- 自动恢复私有服务上的业务登录态；
- 在没有 Dart 监听器和业务协议恢复的情况下执行题词、翻译、对话等 Dart 层业务。

核心结论：State Restoration 只能恢复 CoreBluetooth 物理链路和 GATT 机会窗口。私有服务、notify、CCCD 必须重新初始化，业务认证、通道切换、时间同步等命令必须由 Dart / even_connect 在 `connectFinish` 后重新发送。

## 2. 系统前置条件

iOS 侧必须满足以下条件，否则 State Restoration 只会变成普通前台连接能力：

- `CBCentralManager` 初始化时使用稳定的 `CBCentralManagerOptionRestoreIdentifierKey`。插件只有检测到宿主
  `Info.plist` 已声明 `UIBackgroundModes = bluetooth-central` 时才会传该 restore identifier。
- `Info.plist` 保留 `UIBackgroundModes = bluetooth-central`。
- 已经对目标 peripheral 发起过 `centralManager.connect(peripheral)`，让 CoreBluetooth 持有 pending connect。
- 设备已经达到业务 `connected`，即 Dart 调用过 `deviceConnected(uuid)`，原生才会 arm 自动回连任务。
- 本地存在 reconnect target，可在进程恢复后把 restored peripheral 匹配回 `BleConfig`。

如果宿主没有声明 `bluetooth-central`，iOS 会在带 restore identifier 初始化 `CBCentralManager` 时直接抛
`NSException`。因此插件必须降级为无 restore identifier 的普通 central manager：App 能继续前台扫描和连接，
但不会获得 CoreBluetooth State Restoration 后台唤醒能力。
降级时必须打印可执行的排障日志：`stateRestoration: WARNING disabled because host Info.plist is missing UIBackgroundModes bluetooth-central`，
并提示需要在宿主 `Runner/Info.plist` 添加 `UIBackgroundModes -> bluetooth-central`。

不要依赖 Timer 轮询模拟 iOS 后台唤醒。后台唤醒点应来自 CoreBluetooth pending connect / restoration，而不是 Dart 或原生自己的定时器。

## 3. 生命周期

标准恢复时序：

```text
业务首连成功
  -> Dart 调用 deviceConnected(uuid)
  -> iOS 持久化 reconnect target 并 arm auto reconnect
  -> 异常断连
  -> 原生立即把已知 CBPeripheral 交回 centralManager.connect
  -> App 后台、挂起或被系统回收
  -> 外设回到手机附近
  -> CoreBluetooth 恢复 App 进程
  -> centralManager(_:willRestoreState:) 收到 restored peripheral
  -> initConfigs 完成后匹配 BleConfig
  -> 进入统一 GATT pipeline
  -> connectFinish
  -> Dart 重新发送业务 AUTH / sync 命令
  -> Dart 再次调用 deviceConnected(uuid)
```

`willRestoreState` 可能早于 Flutter 引擎、MethodChannel、EventChannel 和 `initConfigs`。因此回调里只能收集恢复信息，不能直接执行 Dart 业务，也不能假设配置已经可用。

## 4. 模块职责

| 模块 | 职责 |
| --- | --- |
| `BleManager` | 创建带 restore id 的 `CBCentralManager`，接收 CoreBluetooth delegate 回调，统一进入 GATT pipeline。 |
| `BleStateRestorationCoordinator` | 缓存 `willRestoreState` 里的 restored peripherals，等待 `initConfigs` 后再 replay。 |
| `BleStateRestorationFlow` | 把 restored peripheral 匹配到 reconnect target 和 `BleConfig`，决定直接 GATT、继续 connect 或丢弃。 |
| `BleAutoReconnectCoordinator` | 在业务 `connected` 后持有长期 reconnect intent，负责 pending connect、退避、蓝牙关闭暂停。 |
| `BleReconnectStore` | 持久化 reconnect target，并缓存 EventChannel 尚未订阅时发生的 restoration / reconnect 事件。 |
| `BleGattReadiness` | 聚合 service、write characteristic、read characteristic、notify ready 状态，保证 `connectFinish` 只发一次。 |

## 5. Pending Connect 规则

iOS 自动回连的关键不是扫描，而是把已知 `CBPeripheral` 尽快交给 CoreBluetooth：

1. 优先 `retrieveConnectedPeripherals(withServices:)`，服务集合包含配置里的私有服务和 ANCS。
2. 再尝试 `retrievePeripherals(withIdentifiers:)`。
3. 只要拿到 known peripheral，就调用 `centralManager.connect(peripheral)`，让系统持有 pending connect。
4. 没有 known peripheral 但有稳定 name 时，才回退 scan-by-name。

Pending connect 阶段不能使用短连接超时主动取消。设备离开几分钟、几十分钟甚至更久，都应该让 CoreBluetooth 持有这个系统级等待点；短 timeout 只能用于 `didConnect` 之后的 GATT 准备阶段，或前台用户主动连接的可见性反馈。

## 6. ANCS / 系统已连接场景

部分外设会因为 ANCS 或系统蓝牙设置页连接而停止广播。此时 `scanForPeripherals` 扫不到目标并不代表设备不存在。

iOS 连接路由必须先尝试：

```swift
retrieveConnectedPeripherals(withServices: privateServices + [ANCS])
```

命中后应直接进入 `centralManager.connect(peripheral)` / GATT pipeline，不应把扫描不可见映射成 `noDeviceFound`。

## 7. GATT Readiness Gate

State Restoration 恢复后，CoreBluetooth 可能交错返回 cached service、cached characteristic、notify 回调。原生层必须用 readiness gate 聚合状态，不能因第一条 notify 成功就上报 `connectFinish`。

iOS gate 最低要求：

```swift
writeCharsDic.count == bleConfig.privateServices.count
readCharsDic.count == bleConfig.privateServices.count
readCharsNotify == bleConfig.privateServices.count
```

任何一项失败都只能上报现有失败态，例如 `serviceFail`、`charsFail` 或 `timeout`，然后交给 auto reconnect 继续下一轮尝试。

## 8. 取消与继续

以下事件会取消 restoration / auto reconnect 意图：

- 用户或业务主动 `disconnectDevice`；
- `removeDevice` / `removeBond`；
- `resetBle`；
- `cleanConnectCache`；
- 目标配置被删除或 `autoReconnect=false`；
- 插件释放。

以下事件不能取消长期回连意图：

- `timeout`；
- `noDeviceFound`；
- `serviceFail`；
- `charsFail`；
- 蓝牙关闭。

蓝牙关闭只能暂停任务。恢复到 poweredOn 后，iOS 原生层应重新 replay reconnect target，继续 pending connect 或 GATT pipeline。Android 前台“关开蓝牙”改由宿主的 scan-first 流程恢复；扫描未命中时宿主才会显式恢复 Android passive reconnect，不能套用 iOS 的 pending-connect 规则。

## 9. Dart / even_connect 职责

`connectFinish` 只表示 GATT ready，不表示业务 connected。Dart 集成层必须在每次 restoration / auto reconnect 后重新做业务握手：

1. 收到 `connectFinish`。
2. 发送设备业务认证命令。
3. 等待认证成功回调。
4. 调用 `devicePreConnected(uuid)` 进入有界鉴权宽限。
5. 发送业务必要的收尾命令，例如通道切换、时间同步。
6. 调用 `deviceConnected(uuid)`，重新 arm 下一轮 auto reconnect。

如果 Flutter EventChannel 订阅晚于 restoration 事件，Dart 应调用原生提供的 buffered reconnect event drain API，补读原生恢复期间发生的关键事件。

## 10. 日志与实验

关键日志阶段必须可 grep：

- `stateRestoration: willRestoreState`
- `pending-after-initConfigs`
- `restore peripheral`
- `autoReconnect`
- `CBConnectPeripheralOptionEnableAutoReconnect`
- `didConnect`
- `didFailToConnect`
- `didDisconnectPeripheral`
- `connectFinish`

本仓库提供实验脚本：

```bash
./scripts/ios_state_restoration_probe.sh check
./scripts/ios_state_restoration_probe.sh suspend
./scripts/ios_state_restoration_probe.sh kill
./scripts/ios_state_restoration_probe.sh status
```

实验判断：

- `suspend` 模式验证已有进程被挂起后是否能被 BLE 事件继续驱动；
- `kill` 模式验证模拟系统回收后是否出现 `willRestoreState`；
- 真正的 restoration 证据是 `stateRestoration: willRestoreState`，只有 `didConnect` 不足以证明进程经过 State Restoration relaunch。

## 11. 验收清单

- App 首连成功后调用 `deviceConnected(uuid)`，原生持久化 reconnect target。
- 外设离开后 App 后台，原生保持 pending connect，不用短 timeout 取消。
- 系统恢复后能看到 `willRestoreState`，且 restored peripheral 被缓存到 `initConfigs` 之后 replay。
- iOS 蓝牙 poweredOff 只暂停，poweredOn 后继续恢复；Android 前台关开蓝牙由宿主先扫描再连接。
- ANCS / 系统已连接外设扫描不可见时仍可通过 retrieve 路径进入 GATT。
- 每次恢复都重新 discovery service、characteristic、notify / CCCD。
- `connectFinish` 后 Dart 重新发业务认证，认证成功后再 `deviceConnected`。
- 用户主动断连或移除后不再自动恢复。
