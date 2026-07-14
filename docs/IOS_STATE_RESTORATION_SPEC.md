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
  -> restored peripheral 以 source=stateRestoration 进入全局 admission Gate
  -> Gate granted 后才启动 timeout 与统一 GATT pipeline
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
| `BleConnectionAdmissionGate` | 串行所有 endpoint 的 service / characteristic / CCCD / 业务鉴权；restoration、普通 didConnect、already-connected 共用同一 Gate。 |
| `BlePeripheralCancellationBarrierGate` | 用 exact token、2s watchdog 与每 endpoint 单个饱和 debt counter 隔离 cancel 的迟到终态。 |

## 5. Pending Connect 规则

iOS 自动回连的关键不是扫描，而是把已知 `CBPeripheral` 尽快交给 CoreBluetooth：

1. 优先 `retrieveConnectedPeripherals(withServices:)`，服务集合包含配置里的私有服务和 ANCS。
2. 再尝试 `retrievePeripherals(withIdentifiers:)`。
3. 只要拿到 known peripheral，就调用 `centralManager.connect(peripheral)`，让系统持有 pending connect。
4. 缓存端点 UUID 为空但完整设备名非空时，原生以 `belongConfig + 完整设备名` 建立 `identityPending` owner；若缓存 MAC 可用，再校验广播名的 MAC 后缀。此 owner 必须通过激活回执返回给 Dart，不能被静默丢弃。
5. App 并行启动的最多 20s 扫描中，只有配置、完整广播名和可选 MAC 后缀全部匹配时，才允许 pending owner 在普通 MAC/SN 过滤之前吸收该 `CBPeripheral.identifier`，迁移成稳定 UUID task 并立即进入既有直连/Gate 流程。
6. `manufacturerData` 为空的广播只能解析已经明确声明的 pending owner，不能作为普通扫描结果上报，也不能凭名称创建未声明连接。
7. 没有 known peripheral 或 pending identity 时保持长期意图，不在插件内另起 scan-by-name；等待后续 App 扫描、retrieve 或 restoration。

Pending connect 与 Gate 排队阶段都不能使用短连接超时主动取消。设备离开几分钟、几十分钟甚至更久，都应该让 CoreBluetooth 持有这个系统级等待点；`connectTimeout` 只在 `didConnect` 获得 Gate 后启动，并持续覆盖 GATT readiness 与业务鉴权。UI 的 1 分钟展示超时由上层单独管理，不取消 pending connect。

Dart 的 `notifyAutoReconnectTargetVisible` 仅用于 Android passive GATT 的节能退避唤醒；iOS MethodChannel 必须返回 `false` 且不执行 cancel/connect，避免破坏 CoreBluetooth pending connect 与 State Restoration 的单一 owner。

## 6. ANCS / 系统已连接场景

部分外设会因为 ANCS 或系统蓝牙设置页连接而停止广播。此时 `scanForPeripherals` 扫不到目标并不代表设备不存在。

iOS 连接路由必须先尝试：

```swift
retrieveConnectedPeripherals(withServices: privateServices + [ANCS])
```

命中后应直接进入 `centralManager.connect(peripheral)` / GATT pipeline，不应把扫描不可见映射成 `noDeviceFound`。

## 7. 全局 Admission Gate 与 GATT Readiness

所有目标可以同时处于 CoreBluetooth pending connect，但 `didConnect`、系统 already-connected 与 State Restoration callback 都必须提交同一个进程级 Admission Gate：

- automatic / restoration 按真实物理 callback FIFO；
- waiting manual 优先于 automatic，但不能抢占 active owner；
- 只有 owner 能运行 service discovery、characteristic、notify / CCCD 与业务鉴权；
- `connectFinish` 不释放 owner，只有业务 `deviceConnected` 或已确认 teardown 的终态释放；
- 事件携带 `source` 与 `generation`，并通过 endpoint + generation + session + `CBPeripheral` 对象身份拒绝迟到 callback。

State Restoration 恢复后，CoreBluetooth 可能交错返回 cached service、cached characteristic、notify 回调。原生层必须用 readiness gate 聚合状态，不能因第一条 notify 成功就上报 `connectFinish`。

iOS gate 最低要求：

```swift
writeCharsDic.count == bleConfig.privateServices.count
readCharsDic.count == bleConfig.privateServices.count
readCharsNotify == bleConfig.privateServices.count
```

任何一项失败都只能上报现有失败态，例如 `serviceFail`、`charsFail` 或 `timeout`，然后交给 auto reconnect 继续下一轮尝试。

service/char/timeout 等非 CoreBluetooth 终态要先调用 cancel，并保持 Gate owner，直到 `didFailToConnect` / `didDisconnect` 确认 teardown；CoreBluetooth 永不回调时由 2 秒 exact-token watchdog 放行。watchdog 超时债务必须使用每 endpoint 一个饱和 counter，不能保存无限 token 数组。迟到 callback 先消费债务；若新代仍在途则 exact redrive，若新代已业务 connected 且 peripheral 实际断开，则仍继续正常 `disconnectFromSys` 清理与回连，不能把真实断连吞掉。收到终态后必须先释放 exact admission、移除旧 active request，再调度下一 generation；barrier completion 与普通终态只能有一个调度 owner。

蓝牙关闭会清空当前 Gate，因此必须在 teardown 前冻结连接元数据：connecting 端点使用 active admission generation，已业务 connected 端点使用 runtime task 保存的 last connected generation。随后发送的 `disconnectFromSys` 必须携带该 generation，禁止回退为 `unknown/0`，否则 Dart epoch guard 会拒绝终态并保留陈旧已连接状态。

同名扫描结果导致 UUID A→B→C 漂移时，task、持久化 target 与 Gate identity 必须在 admission 前原子迁移。每个 canonical target 最多保留两个 direct alias（最早 UI owner + 最近旧身份）；hard cancel 仍能从原 UI UUID 命中，同时历史 UUID/Gate generation 不线性增长。

## 8. 取消与继续

以下事件会**真取消** restoration / auto reconnect 意图：

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

蓝牙关闭只能暂停任务。恢复到 poweredOn 后，原生层应重新 replay reconnect target，继续 pending connect 或 GATT pipeline。

任何界面上的“取消”都必须调用真取消入口：清 task、持久化 target、`identityPending` owner、pending peripheral/session、timer 与迟到 callback 的复活入口；此后只有再次明确手动点击连接才能重新 activate。自动/手动连接 UI 的 1 分钟超时只停止展示（手动可提示超时），不能隐式调用取消。蓝牙关闭则 teardown Gate/session 并把下一 attempt source 重置为 `autoReconnect`，旧 manual source 不跨 transport reset。

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
- 冷启动/蓝牙恢复时所有 owner 先 activate pending 直连，App 扫描只并行补 cache，最多 20s。
- 系统恢复后能看到 `willRestoreState`，且 restored peripheral 被缓存到 `initConfigs` 之后 replay。
- 蓝牙 poweredOff 先用 active/last-connected generation 上报 `disconnectFromSys`，再暂停任务；poweredOn 后继续恢复。
- ANCS / 系统已连接外设扫描不可见时仍可通过 retrieve 路径进入 GATT。
- 每次恢复都重新 discovery service、characteristic、notify / CCCD。
- `connectFinish` 后 Dart 重新发业务认证，认证成功后再 `deviceConnected`。
- 用户主动断连或移除后不再自动恢复。
- 多 endpoint 的 service/CCCD/业务鉴权不重叠；Gate 只在业务 connected 或 terminal teardown ack/watchdog 后释放。
- 连续 1000 次 cancel watchdog 漏回调仍只有一个 debt counter slot；迟到 debt 不吞业务 connected 后的真实断连。
- UUID 连续漂移仍只保留两个 alias，旧 UI owner 可真取消，历史 Gate identity 不增长。
- UI 一分钟超时不停止 pending connect；点击取消会停止且在下一次手动点击前不会恢复。
