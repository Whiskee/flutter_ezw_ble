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
| iOS | `ota` (1) | WriteWithResponse | **WriteWithoutResponse + 背压** |
| iOS | `stream` (2) | RX 为主,n/a | n/a |
| iOS | `file` (3) | WriteWithResponse | 二期评估(本期不动) |
| Android | 所有 | 已是 `WRITE_TYPE_NO_RESPONSE`(OTA / file) | 不变 |

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

### 4.3 兜底路径

若该 characteristic 不声明 `.writeWithoutResponse` property(理论上 OTA
characteristic 一定支持,此处仅作 defensive),回退到 WriteWithResponse 旧路径,
并打 warn 日志:

```swift
if !supportsNoResponse {
    NSLog("[ezw_ble][warn] OTA characteristic missing writeWithoutResponse property, fallback to withResponse")
    peripheral.writeValue(data, for: characteristic, type: .withResponse)
    pendingWriteCallbacks[uuid] = result
}
```

### 4.4 与 `enterUpgradeState` / `quiteUpgradeState` 的关系

`enterUpgradeState` / `quiteUpgradeState` 不必改动。它们继续控制 connection
参数、断连超时延长等;OTA write type 切换是独立的 per-write 决策。

### 4.5 日志

每次 OTA noResponse 写入(或软节流暂停)打点:

```
[ezw_ble][ota] write uuid=<uuid> bytes=<len> canSend=<bool> queueDepth=<n>
[ezw_ble][ota] pump throttle (sinceLastDrainSync=64), wait peripheralIsReady
[ezw_ble][ota] peripheralIsReady → resume pump (pending=<n>)
```

日志经现有 `logger` EventChannel 上报到 Dart 端 `blePrintEC`(参考 §6 命名约定)。

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
}) async =>
    methodChannel.invokeMethod<void>("sendCmdNoWait", {
      "uuid": uuid,
      "data": data,
      "psType": psType,
    });
```

原生 iOS 侧的 `sendCmdNoWait` 方法实现按 §4.1 / §4.2 决定 write type。

> **保留兼容性**: `sendCmd` Dart API 不动,iOS 原生侧的 `sendCmd` 处理也不动。
> 行为变更仅影响 `sendCmdNoWait` + `psType==1` 的组合 — 这正是 `even_connect`
> 的 `sendOTABytesData` 在 Android 已经用的形态。

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
- 升级途中主动断连 → 设备状态机正确回到 `disconnectFromSys`,不留挂起的 noResponse 写;
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
- [ ] 兜底回退路径 + warn 日志(§4.3);
- [ ] 日志埋点(§4.5);
- [ ] Dart 侧 `MethodChannelEzwBle.sendCmdNoWait` 去掉 iOS fall back(§5);
- [ ] 在内部测试机跑 §6 三类验收 case;
- [ ] 单写 PR,挂"实验性"标签,先合到 dev 分支跑 1 周后再 cherry-pick 到主线。

---

## 10. 联系

Dart 侧团队已完成 G2 队列重构(`even_connect` 仓库),为本次原生侧改造铺好路径。
有任何接口/语义问题请同步到上层 Dart 团队,避免双向假设漂移。
