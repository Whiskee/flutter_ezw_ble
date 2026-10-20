# iOS OTA `WriteWithoutResponse` 改造规范

> 适用版本: `flutter_ezw_ble` 0.0.1 之后版本(待原生团队实施)。
> 配套阅读: `/Users/whiskee/Workspace/EvenDevices/glasses/docs/BLE_PARALLEL_CHANNELS_REPORT.md` 第 5.2 节、`BLE_OPTIMIZATION_PLAN.md` Step 5。
> 负责: 原生 iOS 团队;Dart 侧已就绪,本规范由 Dart 团队提供。

---

## 1. 目标

把 iOS 端 OTA 通道(`BlePrivateService.type == 1`)的 BLE 写入,从当前的
`CBCharacteristicWriteWithResponse`(每包等 `didWriteValueFor` 回调)切换为
`CBCharacteristicWriteWithoutResponse` + `canSendWriteWithoutResponse` 背压,
以打满 iOS 的 packets-per-event 上限(4 包/事件),与 Android 的
`WRITE_TYPE_NO_RESPONSE` 行为对齐。

预期收益: iPhone 12 同一固件包 OTA 总时长 ≤ 改造前 60%。

---

## 2. 现状(改造前)

Dart 端 `MethodChannelEzwBle.sendCmdNoWait`(`lib/flutter_ezw_ble_method_channel.dart`):

```dart
@override
Future<void> sendCmdNoWait(
  String uuid,
  Uint8List data, {
  int psType = 0,
}) async =>
    Platform.isAndroid
        ? methodChannel.invokeMethod<void>("sendCmdNoWait", {
            "uuid": uuid,
            "data": data,
            "psType": psType,
          })
        : sendCmd(uuid, data, psType: psType);
```

iOS 平台直接 fall back 到 `sendCmd`,后者在原生侧走 `CBCharacteristicWriteWithResponse`,每包等 `peripheral:didWriteValueFor:` 回调才返回 — 严重浪费 packets-per-event 带宽。

OTA 调用方位于 `even_connect/lib/core/cmd/even_cmd_service.dart`:

```dart
Future<void> sendOTABytesData(
  String uuid,
  Uint8List data,
) async {
  if (Platform.isAndroid) {
    await EzwBle.to.bleMC.sendCmdNoWait(uuid, data, psType: BleG2PsType.ota.value);
  } else {
    await EzwBle.to.bleMC.sendCmd(uuid, data, psType: BleG2PsType.ota.value);
  }
  await 5.milliseconds.delay();
}
```

iOS 走 `sendCmd`(WriteWithResponse),性能瓶颈即在此。

---

## 3. 目标行为

| 平台 | 通道 (`psType` / `BlePrivateService.type`) | 当前 write type | 改造后 write type |
| --- | --- | --- | --- |
| iOS | `common` (0) | WriteWithResponse | **保持 WriteWithResponse** |
| iOS | `ota` (1) | WriteWithResponse | **WriteWithoutResponse + 背压；成功仅表示已提交 CoreBluetooth** |
| iOS | `stream` (2) | RX 为主,n/a | n/a |
| iOS | `file` (3) | WriteWithResponse | 二期评估(本期不动) |
| Android | OTA (1) | `WRITE_TYPE_NO_RESPONSE` | per-endpoint callback 驱动队列：同步 BUSY 原包重试，`onCharacteristicWrite` 后完成 Future |

Dart 端不改 public API:`bleMC.sendOTABytesData(uuid, data)` 调用链保持不变,
只在 iOS 原生侧拦截 `psType == 1` 的 sendCmd / sendCmdNoWait 走新路径。

---

## 4. 原生侧实施要点

### 4.1 入口分发

在 iOS 原生 `FlutterEzwBlePlugin` 的 `handle:result:` 中,处理 `sendCmd` /
`sendCmdNoWait` 方法时按 `psType` 决定 write type:

```swift
// pseudo-code
let psType = call.arguments["psType"] as? Int ?? 0
let characteristic = lookupCharacteristic(uuid: uuid, psType: psType)

let isOtaChannel = (psType == BlePrivateService.Type.ota.rawValue) // 即 1
let supportsNoResponse = characteristic.properties.contains(.writeWithoutResponse)

if isOtaChannel && supportsNoResponse {
    handleOtaNoResponseWrite(peripheral, characteristic, data, result)
} else {
    // 现有 WriteWithResponse 路径,完全不变
    peripheral.writeValue(data, for: characteristic, type: .withResponse)
    pendingWriteCallbacks[uuid] = result
}
```

`pendingWriteCallbacks` 是现有的 WriteWithResponse 应答队列(由
`peripheral:didWriteValueFor:` 触发 `result(nil)`),不动。

### 4.2 OTA NoResponse 写队列与背压

iOS 通过 `canSendWriteWithoutResponse` + `peripheralIsReadyToSendWriteWithoutResponse:` 做流控。新增一个 per-peripheral 的 OTA 写队列:

```swift
final class OtaWriteQueue {
    private let peripheral: CBPeripheral
    private var pending: [(data: Data, characteristic: CBCharacteristic, result: FlutterResult)] = []
    private var sinceLastDrainSync = 0
    // 每 64 包做一次软节流(等 peripheralIsReady 回调)
    private static let softDrainEvery = 64

    func enqueue(data: Data, characteristic: CBCharacteristic, result: FlutterResult) {
        pending.append((data, characteristic, result))
        pump()
    }

    private func pump() {
        while !pending.isEmpty {
            guard peripheral.canSendWriteWithoutResponse else {
                // 等下一次 peripheralIsReady 回调
                return
            }
            let head = pending.removeFirst()
            peripheral.writeValue(
                head.data,
                for: head.characteristic,
                type: .withoutResponse
            )
            sinceLastDrainSync += 1
            // 立即向 Dart 端回包(无需等回调,WriteWithoutResponse 本就无 ack)
            head.result(nil)

            // 每 N 包主动让出 — 避免 canSendWriteWithoutResponse 不可靠时
            // 突发塞包导致底层丢包(老机型上观察到)
            if sinceLastDrainSync >= Self.softDrainEvery {
                sinceLastDrainSync = 0
                return // 主动暂停,等下一次 peripheralIsReady
            }
        }
    }

    /// CBPeripheralDelegate 回调入口
    func onPeripheralReadyToSendWriteWithoutResponse() {
        pump()
    }
}
```

`CBPeripheralDelegate.peripheralIsReady(toSendWriteWithoutResponse:)` 必须接入到
`OtaWriteQueue.onPeripheralReadyToSendWriteWithoutResponse()`。

生产实现还必须保留有界 watchdog：队首请求首次因
`canSendWriteWithoutResponse == false` 无法提交时开始计时，继续保留原 pending、ready
回调和 100ms 重查；连续 15 秒仍不可写，才以 `ota_write_stalled` 结束该 exact 队首请求，
并保持 stalled 门禁，等待 Dart 的既有恢复处理。15 秒内 callback 或重查确认
`canSend == true` 时，只提交原 pending 一次并取消 watchdog。每次等待/清理必须推进内部
episode，使旧 timer 在取消、reset 或新 attempt 建立后不能驱动新 pending。ready 回调不能在
`canSend` 仍为 false 时重置起始时间，否则虚假/过早 callback 会让 fail-closed 窗口无限延长。

实际队首超时的错误回调前，先移除其同一 batch 中尚未提交的尾包；保留其它 batch/单包。
`pending` 保留清理前含失败队首的历史口径，新增 `remainingPending` 表示上述清理后的
本地未提交条目数。只发布一次错误，迟到 ready/timer 仍被 stalled/episode 门禁拦截。
入队前直接拒绝未执行本次清理，不携带新字段。SDK 可在严格整数 `remainingPending == 0`
且同一 OTA generation、exact physical identity、无当前腿断连等既有条件均成立时，
沿现有直写兜底用新 syncId 重发整个 RAW 窗口；非零/无效证据继续保守恢复，旧 SDK 不变。
本地队列清空不等于 CoreBluetooth drain 或固件 ACK，进度仍只认真实协议响应。

普通 `file` batch 虽复用队列实现，但使用独立实例且没有 OTA recovery owner。
`file_write_stalled` 只永久撤销失败事务的未提交尾包；错误回调前的 `pending` /
`remainingPending` 口径与上述一致。退役完成后，其它已准入及新 file 事务可以继续，
但必须重新检查真实 `canSend`、使用全新的 15 秒等待；不得重放失败事务或清除其它 owner。
每包还须通过当前 file queue 注册、相同物理 peripheral/characteristic、manager 可用及
升级 gate 校验。回调重入若建立新等待/软节流或执行 teardown，旧 continuation/timer
不得覆盖它。OTA 的 stalled gate、真实 ACK、64 包节流及恢复协议均不因此改变。

### 4.3 兜底路径

若该 characteristic 不声明 `.writeWithoutResponse` property(理论上 OTA
characteristic 一定支持,此处仅作 defensive),本期必须 fail closed,向 Dart 返回
`FlutterError(code: "ota_write_unsupported")`,不得回退到旧路径并伪装成功:

```swift
result(FlutterError(
    code: "ota_write_unsupported",
    message: "missing writeWithoutResponse",
    details: ["endpoint": uuid, "reason": "missing writeWithoutResponse", "pending": queueDepth]
))
```

同样 fail closed 的 OTA `sendCmdNoWait(psType == 1)` 前置失败包括:

- BLE manager 当前不可用、蓝牙/配置不可调用: `ota_write_unavailable`;
- device 或 OTA write characteristic 缺失: `ota_write_unavailable`;
- 调用方传入正 `expectedSessionGeneration/expectedAttemptGeneration` 但当前业务 owner
  或 upgrade marker 无法匹配同一物理 attempt: `ota_write_unavailable`;
- CoreBluetooth 提交前外设已释放: `ota_write_unavailable`.

OTA response 经 `receiveData` 回传时会附带 `sessionGeneration/attemptGeneration`。
iOS 没有 Android `BluetoothGatt` 同级别的 handle identity；因此 native 只在当前
`CBPeripheral` 仍 connected，且能从 current admission 或 reconnect owner 解析出正
attempt 时 stamp。升级态 OTA response 解析不到正 pair 会被丢弃，避免旧响应被新
attempt 消费。这个 stamp 不是每条 CoreBluetooth notification 自带的 enqueue-time
物理 token；iOS 无法在迟到 notification 上恢复已经被系统隐藏的旧连接句柄，只能在当前
owner/CBPeripheral 仍一致时给出正 pair。

`disconnectForOtaRecovery` 使用同一 expected pair 专门处理 15 秒 hard stall。调用方必须
传正 `endpoint + expectedSessionGeneration + expectedAttemptGeneration`；native 只有在
当前 owner 完全匹配时才取消该 endpoint 的旧 OTA 写队列、清理该 attempt 的 upgrade marker，
并发起真实 `cancelPeripheralConnection`。该 API 不伪造断连事件、不清 normal
autoReconnect owner，返回值为 `accepted`、`alreadyDisconnected`、`staleIdentity` 或
`unavailable`。断开后的业务回连、AUTH、重新进入 upgrade state、START/INFORMATION/RAW
由上层 OTA 恢复链负责。

`disconnectForOtaReboot` 继续用于 firmware reboot teardown。调用方传正数时，native 在执行
reboot teardown 前必须匹配当前 owner；不匹配直接拒绝，不 detach 旧物理链路、不发布
`.disconnectFromSys`、不注册 suppression。teardown 后的迟到断连 suppression 也绑定同一
pair：Android 绑定 admission + GATT callback pair，iOS 绑定 `CBPeripheral` 对象 +
owner pair；旧 teardown 不能被新 attempt 消费。0/0 只用于旧调用兼容。

Android `sendCmdNoWait(psType == 1)` 同样必须保留 `BluetoothGatt.writeCharacteristic`
同步状态。`ERROR_GATT_WRITE_REQUEST_BUSY` 是单槽位背压，不是包错误：原包进入 per-endpoint
队列，等待当前 `onCharacteristicWrite` 释放槽位后重试；提交成功后本包 Future 仍等自己的
`onCharacteristicWrite` 成功才返回。iOS 本轮 hard-stall recovery 不改变 Android 既有
等待/取消策略；非 OTA no-wait 路径保持原行为。

### 4.4 与 `enterUpgradeState` / `quiteUpgradeState` 的关系

`enterUpgradeState` 继续控制 connection state marker。`quiteUpgradeState` 可携带
`expectedSessionGeneration/expectedAttemptGeneration`，用于避免旧 attempt 的迟到清理
误消费新 attempt；OTA write type 切换仍是独立的 per-write 决策。

### 4.5 日志

每次 OTA noResponse 写入、可写恢复、停滞和取消打确定性日志:

```
[ezw_ble][ota] enqueued endpoint=<uuid> bytes=<len> pending=<n>
[ezw_ble][ota] submitted endpoint=<uuid> char=<charUuid> bytes=<len> pending=<n>
[ezw_ble][ota] backpressure endpoint=<uuid> episode=<n> reason=<reason> wait=<duration> pending=<n>
[ezw_ble][ota] ready endpoint=<uuid> episode=<n> canSend=<bool|released> pending=<n>
[ezw_ble][ota] resumed endpoint=<uuid> episode=<n> reason=<reason> source=<callback|poll> wait=<duration> pending=<n>
[ezw_ble][ota] stalled endpoint=<uuid> episode=<n> reason=<reason> wait=<duration> pending=<n> session=<n> attempt=<n>
[ezw_ble][ota] cancelled endpoint=<uuid> episode=<n> reason=<reason> pending=<n>
```

日志经现有 `logger` EventChannel 上报到 Dart 端 `blePrintEC`(参考 §6 命名约定)。

#### 4.5.1 发送就绪诊断

部分 iOS 26.x 手机上 `canSendWriteWithoutResponse` 长期为 false 且 ready 回调不到,但写入
仍能送达。仅凭 OTA 队列日志无法区分"标志失效"与"链路真的拥塞",因此补充以下只读采样:

```
[ezw_ble][ota] queue created uuid=<uuid> peripheral=<对象地址>
[ezw_ble][wwr] ready uuid=<uuid> canSend=<bool> queue=none peripheral=<对象地址>
sendCmd: <uuid>, type=<psType>, writeChars=<charUuid>, data length =<len>, canSendBefore=<bool>, canSendAfter=<bool>, peripheral=<对象地址>
sendCmdNoWait: <uuid>, type=<psType>, writeChars=<charUuid>, data length=<len>, canSendBefore=<bool>, canSendAfter=<bool>, peripheral=<对象地址>
```

- `[ezw_ble][wwr] ready` 只在该外设没有 OTA 队列时输出;有队列时由 `[ezw_ble][ota] ready`
  记录,同一次回调不会输出两行。
- `canSendBefore` 在 `writeValue` 之前采样,`canSendAfter` 在之后读取。
- `peripheral` 是 `CBPeripheral` 对象地址,用于判断重连前后是否为同一实例。
- 以上采样只用于日志。普通通道(`sendCmd`、非 OTA 的 `sendCmdNoWait`)仍然不读取该标志
  就直接写出,不得把采样值用于任何放行判断。

判读:

| 现象 | 含义 |
| --- | --- |
| `canSendBefore=false` 的写入随后收到设备协议回复 | 标志失效,链路实际可写 |
| 写入之后长时间没有任何 `ready` 行 | 系统没有回送 ready |
| `ready` 行里 `canSend=false` | 回调到达但标志未恢复 |
| 重连前后 `peripheral` 地址相同 | CoreBluetooth 复用了同一对象 |

---

## 5. Dart 侧需要同步的最小改动

**改一处**: `flutter_ezw_ble/lib/flutter_ezw_ble_method_channel.dart` 的
`sendCmdNoWait` iOS 分支不再 fall back 到 `sendCmd`,改成直接走原生
`sendCmdNoWait`:

```dart
@override
Future<void> sendCmdNoWait(
  String uuid,
  Uint8List data, {
  int psType = 0,
  int expectedSessionGeneration = 0,
  int expectedAttemptGeneration = 0,
}) async =>
    methodChannel.invokeMethod<void>("sendCmdNoWait", {
      "uuid": uuid,
      "data": data,
      "psType": psType,
      "expectedSessionGeneration": expectedSessionGeneration,
      "expectedAttemptGeneration": expectedAttemptGeneration,
    });
```

原生 iOS 侧的 `sendCmdNoWait` 方法实现按 §4.1 / §4.2 决定 write type。

> **保留兼容性**: `sendCmd` / `sendCmdNoWait` / `quiteUpgradeState` 的
> `expectedSessionGeneration/expectedAttemptGeneration` 默认均为 `0/0`，旧调用语义不变。
> 上层 OTA 恢复传正 pair 后，native 才启用 exact attempt guard。G2 OTA transaction
> 另外通过 nested `otaContext {transactionId, generation, instanceId}` 传入；
> native 必须同时校验 transaction 和 physical pair，旧 UUID-only 或 physical-only 调用不能清理新事务。
>
> **成功语义**: `sendCmdNoWait(psType==1)` 的 Future 成功只表示 native 已经调用
> `peripheral.writeValue(..., type: .withoutResponse)`,即提交到 CoreBluetooth transmit
> queue;它不是设备收到包、写入 flash、CRC 通过或任何应用层 ACK。设备确认仍由 OTA
> 协议自身的 CRC/状态回包/超时重试承担。

Native OTA marker 由非可选 `BleUpgradeStateRegistry` 和 G2 OTA transaction registry 持有：
进入升级态必须真实插入 endpoint，普通 `sendCmdNoWait` 在 marker 存在时默认拒绝；退出时先消费
marker，再校验 live peripheral 与 accepted epoch。G2 首腿完成使用 transaction `park` 隔离旧
transport；最终整组 `finish` 可在 CBPeripheral 已释放后凭已登记 transaction 退役旧资源。这样
Bluetooth OFF 或迟到 OTA exit 都不能复活旧连接，也不能让旧清理作用于新 OTA。

---

## 6. 验收

### 6.1 功能性验收

- iOS 端 OTA 全流程跑通(从 `prepareOTAUpgrade` 到 `BleG2OTATransmitStatus.success`),与改造前结果一致;
- 30 次 OTA 测试 0 失败(机型: iPhone 12 / iPhone 14 / iPhone 15);
- 升级期间 common 通道心跳 RTT 与改造前同分布(p50 / p95 不退化);
- 退出升级后,常规业务指令往返时间不退化。

### 6.2 性能验收

- 固定 5 MB 固件包,iPhone 12 实测 OTA 总时长 ≤ 改造前 60%(目标值,实际可能更好);
- 通过观察 native 日志,确认 `peripheralIsReady` 回调频次合理(不应每包都触发,
  也不应长时间无回调);
- 软节流(每 64 包暂停)实际触发频次记录在日志中,供 tuning 参考。

### 6.3 健壮性验收

- BLE 信号弱场景(走廊外)下 OTA 仍能完成,失败时通过应用层 CRC 检验触发 retry;
- 升级途中主动断连 → 设备状态机正确回到 `disconnectFromSys`,挂起的 noResponse 写以
  `ota_write_cancelled` 结束,不留 Dart await;
- 队首写入连续 14.9 秒不可提交 → 原 pending 仍等待；随后 ready 只提交原请求一次，不重连；
- 队首写入连续 15 秒不可提交 → 仅该 exact noResponse head 以 `ota_write_stalled`
  结束所属请求（batch 同时清除未提交尾包），迟到 ready/timer/callback 不得发送旧包，details 带
  `endpoint/reason/wait/pending/remainingPending/session/attempt`；其它请求保留并计入残留；
- exact recovery cancel/replacement 清理后，新 episode 可正常发送；
- App 退后台 / 锁屏期间不掉包(iOS 后台 BLE 允许 OTA 类长时操作)。

---

## 7. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| `canSendWriteWithoutResponse` 在老 iPhone(iPhone 6s / SE 一代)上"报喜不报忧",突发塞包丢失 | 每 64 包软节流主动等 `peripheralIsReady`(§4.2) |
| OTA characteristic 不声明 `.writeWithoutResponse` property | §4.3 兜底回退 + warn 日志 |
| 改造后 iOS 端 OTA 包顺序乱了 / 包间隔过短设备处理不过来 | 软节流 + 必要时调整 `softDrainEvery` 阈值(配置常量,可后续 tuning) |
| 与 `enterUpgradeState` 中 connection 参数调整冲突 | 不耦合,独立分支 |
| Dart 端 `sendOTABytesData` 调用方依赖"每包 await 完成才发下一包"的隐含同步语义 | 现有调用形如 `await sendOTABytesData(...)`,改造后 native 侧仍立即 result(nil),Dart 侧 `await` 立即返回;调用方无感知 |

---

## 8. 不在范围

- `psType == 3` (file) 通道的 noResponse 改造 —— 二期评估;
- iOS connection interval 协商 —— 独立分支;
- `psType == 0` (common) write type 切换 —— 维持 WriteWithResponse(应答匹配机制依赖);
- BT 5.2 EATT / L2CAP CoC —— 外设固件不支持,本期不做。

---

## 9. 实施清单(给原生团队)

- [ ] `FlutterEzwBlePlugin.swift` `handle:result:` 中 `sendCmd` / `sendCmdNoWait` 入口按 §4.1 分发;
- [ ] 新增 `OtaWriteQueue.swift`(§4.2);
- [ ] 在 `CBPeripheralDelegate` 实现里把 `peripheralIsReady(toSendWriteWithoutResponse:)` 接到 `OtaWriteQueue`;
- [ ] OTA unsupported/unavailable fail closed typed error(§4.3);
- [ ] 日志埋点(§4.5);
- [ ] Dart 侧 `MethodChannelEzwBle.sendCmdNoWait` 去掉 iOS fall back(§5);
- [ ] 在内部测试机跑 §6 三类验收 case;
- [ ] 单写 PR,挂"实验性"标签,先合到 dev 分支跑 1 周后再 cherry-pick 到主线。

---

## 10. 联系

Dart 侧团队已完成 G2 队列重构(`even_connect` 仓库),为本次原生侧改造铺好路径。
有任何接口/语义问题请同步到上层 Dart 团队,避免双向假设漂移。

## 11. 真实ACK测量与定时器换代（2026-10-13，预算回收已撤销）

本节描述当前实现；前文示例与最初实施清单不代表所有现行队列细节。

- soft64的500ms等待切换为 `canSend=false` 的100ms重查时，必须先取消并清空旧任务句柄，再为新episode建任务。取消后仍执行的旧block不能清新句柄；重复false不刷新15秒单调时钟起点。
- OTA RAW批次可携独立 `otaWindow={windowId,expectedAck}`。本地ID不写入固件协议，native完成只标记全批已提交，不回收预算。
- 只有当前owner（UUID、session、attempt、transaction、OTA generation、instance）完整匹配且native实际收到标准成功RAW ACK `AA 12 SS 04 01 01 C1 00 02 00 6D 7B` 才签发一次性receipt。Dart还需验证当前窗口、物理身份、事务、方向、SID/SS/CID/CRC和成功状态；早到ACK不能绕过尚未完成的批次Future。
- 收据继续捎带到下一FILE的既有 `sendCmdNoWait` 参数 `otaWindowCredit`，native需队列空、owner/window/receipt匹配以及完整合法FILE帧，才记录ACK测量锚点。该兼容键不再授权预算回收：即使收据有效，也不清零累计包数、不解除soft64等待、不取消retry、不驱动pending。64包软等待只由原有ready/poll恢复；普通FILE队列不消费OTA收据。
- `nativeNotifyToCreditMs` 保留历史字段名，现仅计notify→下一FILE准入消费receipt；`nativeAckToNextFileMs` 计notify→该FILE实际提交给CoreBluetooth，包含该FILE遭遇的soft64或hard backpressure。已完成的单包FILE软等待携带到后继RAW的measured result，不在receipt到达时提前结算或解除等待。其他软等待、timer迟到、poll/callback恢复次数仍输出批次/组件汇总，均非空口时间。
- cancel、stall、peripheral释放或事务/物理owner清理不得保留旧receipt。旧批次失败只作废其自己的window，不能清掉新window。
- 回归入口：`fvm flutter test test/ios_ota_queue_native_test.dart test/ota_window_bridge_test.dart`（host Swift行为测试仅macOS执行）；SDK生产发送链路另见其 strict ACK 与window credit回归测试。

当前A/B版本只保留定时器修复及观察埋点，不启用64包预算回收；是否恢复速度须固定手机、固件和构建配置做真机对比。没有修改MTU/4KB协议、真实ACK、固件处理或iOS无线调度。固件只有8位SS而无窗口nonce，不声称解决所有空口旧帧重放。

## 12. 普通文件批次的可选逻辑撤权

文件调用方可通过 `beginFilePacketBatch` 获取当前原生文件队列的单次 reservation，
然后向 `sendFilePacketBatch` 传入 `fileBatchToken`。`cancelFilePacketBatch` 先退役该
身份，再只删除匹配的未提交尾包并结束该批次 await；其它文件请求与 OTA 队列不被清空。
取消前尚未提交的 reservation 也会失效，迟到 send 或旧 cancel 不能操作新 reservation。

这不是 CoreBluetooth 写入撤回或固件 ACK。仍保留 64 包预算、500ms 软等待、100ms
背压重查、15 秒 stall 与每包物理目标复验；精确取消不能清零预算或让旧 timer 驱动新
批次。持续 canSend=false 的机型兼容性仍需调用方独立决策，不能用此接口绕过背压。
完整桥接及生命周期契约见 [ARCHITECTURE](../ARCHITECTURE.md#文件批次的精确撤权)。
