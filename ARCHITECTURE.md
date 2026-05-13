# flutter_ezw_ble · 架构与协议手册

> 适用范围：`flutter_ezw_ble` 插件本身（Dart 层），不含 `flutter_ezw_utils` 依赖。
> 用途：作为后续修改本仓库（重构/扩展 API / 协议升级）的指引文档。
> 阅读对象：负责改动 BLE 插件的工程师；改动前请先通读本文。
> 文档版本对齐：`pubspec.yaml` 中 `version: 0.0.1`，对应当前 `lib/` 目录。

---

## 1. 插件定位

`flutter_ezw_ble` 是一个**配置驱动的通用 BLE 通信插件**，把"扫描 → 连接 → 收发数据 → 升级"这条 BLE 流水线封装为统一的 Dart API + Flutter Method/Event Channel 桥接。

它不绑定任何具体设备型号。所有"如何识别一个目标设备""走哪条 GATT 服务""SN 怎么解析""MAC 怎么从广播里取出来"全部通过传入的 `BleConfig` 配置告诉原生层；插件本体只负责：

- 把 Dart 侧的配置/指令翻译成原生 BLE 操作；
- 把原生 BLE 状态、扫描结果、连接进度、收到的特征值数据通过 Event Channel 推回 Dart。

业务侧（如 `even_connect`）在这层之上注册多套 `BleConfig`（G1、G2、Ring1…），按"配置名（belongConfig）"来区分对接哪类设备。

> **重要**：本仓库 `lib/` 是 Dart 侧实现的主入口。原生侧 `FlutterEzwBlePlugin` 已纳入仓库 `android/` 与 `ios/` 子目录（Kotlin / Swift），与 Dart 侧同仓维护：
>
> - `ios/Classes/`：`FlutterEzwBlePlugin.swift` 注册 + `ble/BleManager.swift`（CoreBluetooth）+ `ble/BleChannel.swift`（MethodChannel 分发）+ `ble/OtaWriteQueue.swift`（OTA `WriteWithoutResponse` 背压队列，配套规范 `IOS_OTA_NOWAIT_SPEC.md`）；
> - `android/src/main/kotlin/com/fzfstudio/ezw_ble/`：`FlutterEzwBlePlugin.kt` + `ble/BleManager.kt`。
>
> 改动 Dart API 时一并评估原生侧两端的联动；个别协议/性能改造（如 OTA 的 `sendCmdNoWait`）会有独立 spec 文档，落地时优先按 spec 走。

---

## 2. 整体架构

```
                       ┌──────────────────────────────────────────┐
                       │              业务侧（如 even_connect）   │
                       │  注册 List<BleConfig> → 监听 EzwBle 流  │
                       └────────────┬───────────────┬────────────-┘
                                    │ MethodChannel │ EventChannel
                                    │ (单向调用)    │ (持续推送)
                       ┌────────────▼───────────────▼────────────┐
                       │              flutter_ezw_ble Dart 层    │
                       │                                          │
                       │  ┌────────────┐    ┌─────────────────┐  │
                       │  │ EzwBle.to  │←──→│ MethodChannelEzw│  │
                       │  │ (singleton)│    │ Ble (调用入口) │  │
                       │  └─────┬──────┘    └─────────────────┘  │
                       │        │                                 │
                       │        │      ┌─────────────────────┐    │
                       │        └─────→│ BleEventChannel     │    │
                       │               │ (5 路推流)          │    │
                       │               └─────────────────────┘    │
                       │                                          │
                       │   Models: BleConfig / BleScan / BleSnRule│
                       │           BleMacRule / BlePrivateService │
                       │           BleDevice / BleMatchDevice     │
                       │           BleConnectModel / BleCmd ...   │
                       └────────────┬─────────────────────────────┘
                                    │ Pigeon / MethodChannel
                       ┌────────────▼─────────────────────────────┐
                       │          原生 BLE 实现（外部仓库）        │
                       │   iOS: CoreBluetooth                     │
                       │   Android: BluetoothGatt + 配对/绑定逻辑 │
                       └──────────────────────────────────────────┘
```

核心思想：**配置在 Dart 侧定义，执行在原生侧**。每一份 `BleConfig` 都会被序列化并通过 `initConfigs` 注入到原生层，原生层据此识别广播、解析 SN、走 GATT、决定是否主动 bond。

---

## 3. 目录结构

```
lib/
├── flutter_ezw_ble.dart                  # 单例 EzwBle，统一聚合 MethodChannel + EventChannel
├── flutter_ezw_index.dart                # 库门面，对外 export 全部 public 类型
├── flutter_ezw_ble_platform_interface.dart  # 平台接口（plugin_platform_interface）
├── flutter_ezw_ble_method_channel.dart   # MethodChannel 默认实现
├── flutter_ezw_ble_event_channel.dart    # EventChannel 枚举 + 单例缓存
└── core/
    ├── models/                            # 数据模型（全部 JsonSerializable）
    │   ├── ble_config.dart               # 顶层配置
    │   ├── ble_scan.dart                 # 扫描规则
    │   ├── ble_sn_rule.dart              # SN 识别规则
    │   ├── ble_mac_rule.dart             # MAC 识别规则（仅 iOS）
    │   ├── ble_private_service.dart      # 自定义 GATT 服务/读写特征
    │   ├── ble_device.dart               # 单个 BLE 设备
    │   ├── ble_match_device.dart         # 组合设备（按 SN 聚合多个 BLE 设备）
    │   ├── ble_connect_state.dart        # 连接状态机枚举
    │   ├── ble_connect_model.dart        # 连接状态事件
    │   ├── ble_status.dart               # 蓝牙开关/权限状态
    │   ├── ble_cmd.dart                  # 收发的字节命令
    │   └── ble_device_hardware.dart      # 设备硬件信息（电量/版本，G1 解析协议）
    ├── tools/
    │   └── connect_state_converter.dart  # BleConnectState 的 JSON 转换器
    └── extension/
        ├── ble_device_ext.dart           # 给 Rx<BleMatchDevice?> 增加 update() 助手
        └── string_ext.dart               # MAC 大小端互转
```

> 所有 `*.g.dart` 是 `json_serializable` 生成产物，**不要手工修改**；模型字段调整后跑 `dart run build_runner build --delete-conflicting-outputs` 重新生成。

---

## 4. 公共入口：`EzwBle`

`lib/flutter_ezw_ble.dart` 的 `EzwBle` 是一个**单例聚合**：把"调原生"和"听原生事件"两件事统一暴露。

```dart
class EzwBle {
  static final EzwBle to = EzwBle._init();

  /// 调原生：所有主动操作（扫描/连接/发指令/重置 BLE 等）走这里
  MethodChannelEzwBle bleMC = MethodChannelEzwBle();

  /// 听原生（5 路 Stream，懒加载、广播流）
  Stream<BleState>        bleStateEC;       // 蓝牙开关/权限
  Stream<String>          blePrintEC;       // 原生层日志（含 [d]- / [e]- 前缀）
  Stream<BleMatchDevice>  scanResultEC;     // 扫描命中
  Stream<BleConnectModel> connectStatusEC;  // 连接流程逐阶段进度
  Stream<BleCmd>          receiveDataEC;    // GATT 特征值通知
}
```

使用范式（业务侧）：

```dart
// 1. 配置注入（一次）
await EzwBle.to.bleMC.initConfigs([
  BleConfig(...G1配置...),
  BleConfig(...G2配置...),
]);

// 2. 监听
EzwBle.to.bleStateEC.listen((s) => print(s));
EzwBle.to.scanResultEC.listen((d) => print(d.sn));
EzwBle.to.connectStatusEC.listen((c) => print(c.connectState));
EzwBle.to.receiveDataEC.listen((cmd) => print(cmd.data));

// 3. 主动调用
await EzwBle.to.bleMC.startScan();
await EzwBle.to.bleMC.connectDevice('g2_glasses', uuid, name, sn: sn);
await EzwBle.to.bleMC.sendCmd(uuid, Uint8List.fromList([0xAA, ...]));
```

### 4.1 命名常量

```dart
const String ezwBleTag = "flutter_ezw_ble";
```

- MethodChannel 名固定为 `flutter_ezw_ble`；
- EventChannel 名拼接为 `flutter_ezw_ble_<enumName>`，例：`flutter_ezw_ble_scanResult`。

> **修改提示**：改 `ezwBleTag` 必须同步改原生侧的 channel 名常量。

---

## 5. MethodChannel API 参考

平台接口位于 `FlutterEzwBlePlatform`（抽象），默认实现 `MethodChannelEzwBle`。下表列出每个方法的"协议名 / Dart 签名 / 参数 / 行为约束"。

| 协议名 (`MethodChannel.method`) | Dart 签名 | 用途 |
| --- | --- | --- |
| `getPlatformVersion` | `Future<String?> getPlatformVersion()` | 调试用，返回原生版本字符串。 |
| `bleState` | `Future<int> bleState()` | 主动查询当前蓝牙状态码，配合 `BleStateExt.from(int)` 解码。 |
| `initConfigs` | `Future<void> initConfigs(List<BleConfig> configs)` | **必须最先调用**。把多份配置一次性下发给原生层；下发参数是 `configs.map((c) => c.customToJson())`（保证嵌套 model 也序列化）。 |
| `startScan` | `Future<void> startScan({bool turnOnPureModel = false})` | 启动扫描。`turnOnPureModel = true` 时跳过 SN/MAC 规则、回原始广播（用于排障）。 |
| `stopScan` | `Future<void> stopScan()` | 显式停止扫描。 |
| `connectDevice` | `Future<void> connectDevice(String belongConfig, String uuid, String name, {String? sn, bool? afterUpgrade})` | 发起连接。`belongConfig` 必须命中 `initConfigs` 注册过的配置名；`name` 在 iOS 端定位，`sn` 仅 Android 用；`afterUpgrade=true` 时走 OTA 后的特殊重连路径。 |
| `disconnectDevice` | `Future<void> disconnectDevice(String uuid, String name, {bool removeBond = false})` | 主动断连。`removeBond=true`（仅 Android）会一并移除系统配对。 |
| `devicePreConnected` | `Future<void> devicePreConnected(String uuid)` | "预连接"通知：业务确认要连这个设备前，让原生侧提前做准备（缓存、超时计时器复位），避免接下来的 `connectDevice` 超时。 |
| `deviceConnected` | `Future<void> deviceConnected(String uuid)` | "真连上了"通知：业务侧（如收到设备配对回包后）告诉原生 "连接已业务就绪"，原生再 push `connectFinish` → `connected`。 |
| `sendCmd` | `Future<void> sendCmd(String uuid, Uint8List data, {int psType = 0})` | 写特征值，等待原生层 write 完成。`psType` 是"私有服务类型"，对应 `BlePrivateService.type`（0=基础，1=OTA，2+=自定义）。 |
| `sendCmdNoWait` | `Future<void> sendCmdNoWait(String uuid, Uint8List data, {int psType = 0})` | 不等 write callback，连发场景使用。Android：`WRITE_TYPE_NO_RESPONSE` 写入。iOS：`psType == 1`（OTA）走 `WriteWithoutResponse` + `canSendWriteWithoutResponse` 背压队列（见 `ios/Classes/ble/OtaWriteQueue.swift` 与 `IOS_OTA_NOWAIT_SPEC.md`），其它 `psType` 退化为 `WriteWithoutResponse` 立即返回路径。 |
| `enterUpgradeState` | `Future<void> enterUpgradeState(String uuid)` | 标记此 uuid 进入 OTA。原生侧据此切到 OTA 私有服务、延长断连超时（与 `BleConfig.upgradeSwapTime` 配合）。 |
| `quiteUpgradeState` | `Future<void> quiteUpgradeState(String uuid)` | 退出 OTA 状态。 |
| `openBleSettings` | `Future<void> openBleSettings()` | 跳系统蓝牙开关页。 |
| `openAppSettings` | `Future<void> openAppSettings()` | 跳本 App 权限设置页。 |
| `resetBle` | `Future<void> resetBle()` | 让原生层重置内部 BLE 栈状态（清队列、断所有连接、清缓存）。 |
| `cleanConnectCache` | `Future<void> cleanConnectCache()` | 清"上次连接的设备"等连接缓存，不动 GATT。 |

> **修改提示**：新增 MethodChannel 方法时，三处都要改：① `FlutterEzwBlePlatform`（抽象签名 + 默认 `UnimplementedError`）；② `MethodChannelEzwBle`（`@override` + `methodChannel.invokeMethod`）；③ 原生侧两个平台的 `onMethodCall` 分支。

---

## 6. EventChannel 推流参考

`BleEventChannel` 枚举定义了所有事件通道：

```dart
enum BleEventChannel {
  bleState,       // → int        → BleState
  scanResult,     // → String(JSON)→ BleMatchDevice
  connectStatus,  // → String(JSON)→ BleConnectModel
  receiveData,    // → Map        → BleCmd
  logger,         // → String     → 原生日志
}
```

`BleEventChannelExt.ec` 内部用一个 `List<(channel, stream)>` 做缓存，**同一个 channel 多次访问拿到的是同一个广播流**。这点改动时要注意：如果新增 channel 后改成 `final` map 之类，要保持"同一个 broadcast stream 不会重订阅"。

各路事件的语义：

| 事件 | 原始数据 | Dart 映射 | 含义 |
| --- | --- | --- | --- |
| `bleState` | `int`（iOS CoreBluetooth state 值，扩展 `6 = noLocation` 给 Android） | `BleState` | 蓝牙开关、定位权限变化；启动时也会主动 push 一次。 |
| `scanResult` | JSON 字符串 | `BleMatchDevice.fromJson` | 一次扫描命中（按 `BleScan.matchCount` 已聚合好的"组合设备"）。 |
| `connectStatus` | JSON 字符串 | `BleConnectModel.fromJson` | 连接流程的每一步推进（见 §8）。 |
| `receiveData` | Map：`{uuid, psType, data:Base64, isSuccess}` | `BleCmd.receiveMap` | 来自原生的特征值数据。**注意 `data` 字段是 Base64**，业务侧拿到的 `BleCmd.data` 已经是 `Uint8List`，背后由 `flutter_ezw_utils.encodeBase64()` 解码。 |
| `logger` | String，含 `[d]-` / `[e]-` 前缀 | `String` | 仅 iOS 主动 push；业务侧自行根据前缀分级。 |

> **修改提示**：`receiveData` 的 `data` 走 Base64 是为了避开 MethodChannel 二进制流跨 isolate 的成本；新增二进制通道时建议沿用这套约定。

---

## 7. 数据模型详细参考

### 7.1 `BleConfig` — 顶层配置

```dart
@JsonSerializable()
class BleConfig {
  final String  name;             // 配置名，唯一键
  final BleScan scan;             // 扫描+SN/MAC 规则
  final List<BlePrivateService> privateServices;
  final bool   initiateBinding;   // 是否主动发起绑定流程
  final double connectTimeout;    // 单次连接超时（ms），默认 15000
  final double upgradeSwapTime;   // 升级后启动新固件等待时间（ms），默认 60000，重连时用
  final int    mtu;               // 仅 Android 用，默认 247
}
```

`customToJson()` 与默认 `toJson()` 的区别：前者会把 `privateServices` 和 `scan` 都按子模型的 toJson 展开，避免嵌套对象被序列化成 `_$BleScanFromJson` 这种内部结构。**`initConfigs` 调用走的就是 `customToJson`**。

### 7.2 `BleScan` — 扫描规则

```dart
class BleScan {
  final List<String> nameFilters;  // 广播名前缀过滤
  final BleSnRule?   snRule;       // SN 识别（按字节区间截取广播）
  final BleMacRule?  macRule;      // MAC 识别（仅 iOS 用）
  final int          matchCount;   // 1=单设备，>=2 启用"组合设备"匹配模式
}
```

- `nameFilters` 不能空，构造时有 assert；
- `matchCount` 表达"一个 SN 对应几个 BLE 端点"——G1/G2 是 2（左右腿），戒指是 1。

### 7.3 `BleSnRule` — SN 解析

```dart
class BleSnRule {
  final int    byteLength;   // SN 总长，0 表示不限
  final int    startSubIndex;// 从广播包第几个字节开始截取
  final String replaceRex;   // 去除控制字符的正则，默认 [\x00-\x1F\x7F]
  final List<String> filters;// SN 前缀白名单，避免命中非 Even 设备
}
```

构造 assert：`byteLength == 0 || byteLength > startSubIndex`。

### 7.4 `BleMacRule` — iOS 专用

```dart
class BleMacRule {
  final int  startIndex;
  final int  endIndex;
  final bool isReverse;   // iOS 上常需要把广播里的 MAC 字节反转再用
}
```

iOS CoreBluetooth 不暴露 MAC，需要靠厂商广播段截取。Android 直接拿系统 MAC，不需要此规则。

### 7.5 `BlePrivateService` — GATT 服务声明

```dart
class BlePrivateService {
  final String service;     // service UUID
  final String writeChars;  // 写特征 UUID
  final String readChars;   // 读/通知特征 UUID
  final int    type;        // 0=基础，1=OTA，>=2 自定义（与 sendCmd 的 psType 联动）
}
```

一个 `BleConfig.privateServices` 可以包含多条，G2 就是 4 路服务（common / ota / stream / file）。

### 7.6 `BleDevice` / `BleMatchDevice` / `BleConnectModel`

```dart
class BleDevice {
  final String belongConfig;   // 命中的 BleConfig.name
  String uuid;                 // iOS=peripheral UUID, Android=MAC
  String name;
  String sn;
  int    rssi;
  String mac;                  // iOS 通过 BleMacRule 解析；Android = uuid
  BleConnectState connectState;
}

class BleMatchDevice {
  final String sn;
  final List<BleDevice> devices;     // 一台设备的所有 BLE 端点
  String remark;                     // App 侧的备注（不参与 JSON 序列化）
  String get belongConfig => devices.first.belongConfig;
  // ... 一组聚合 getter：isConnecting / isConnected / isAllDisconnected / isBound 等
  bool isSameDevice(BleMatchDevice other);
}

class BleConnectModel {
  final String uuid;
  final String name;
  @ConnectStateListConverter()
  final BleConnectState connectState;
  final int mtu;                     // 默认 512，Android 协商后实际值通过此字段回传
}
```

`BleMatchDevice` 是这层最重要的"业务侧设备实体"，它的所有 `isXxx` getter 都是"按 devices 列表多数/任意判断"，G2 左右腿任一断开就视为整机 `isDisconnected`。

### 7.7 `BleCmd`

```dart
class BleCmd {
  final String   uuid;
  final int      psType;
  final Uint8List? data;     // receiveMap 解 Base64 后填进来
  final bool     isSuccess;
}
```

接收端调用静态构造 `BleCmd.receiveMap(Map)` 走 Base64 解码；发送端直接构造对象但目前没有发送序列化路径——发送统一走 `EzwBle.to.bleMC.sendCmd(uuid, Uint8List)`。

### 7.8 `BleDeviceHardware`

G1/G2 共用的"设备硬件信息"模型，20 字节定长，按 `BleDeviceHardware.fromByte(Uint8List, bool isMaster)` 解析。字段含义详见模型文件注释：

| 字段 | 含义 | 备注 |
| --- | --- | --- |
| `batteryStatus0` / `batteryStatus1` | master / slave 电量 0-100 |  |
| `chargingVBat` | 充电电压：`(data[4] + 200) / 100` |  |
| `chargingCurrent` | 充电电流：`data[5] - 128`，<128 充电 / >128 放电 |  |
| `chargingTemp` | 充电温度 0-100 摄氏度 |  |
| `devVer0..5` | 设备软件版本号，左右腿各占 3 字节 |  |
| `flashVer0..1` | flash 版本号 |  |
| `mHwVer` / `sHwVer` | 主从硬件版本号 |  |
| `bleVer0..1` / `bleHwVer` | BLE 软/硬件版本（**未启用**） |  |
| `bootSeconds`, `isMaster`, `isSuccess`, `version` | App 侧填充 | G2 直接用 `version` 字符串 |

`get deviceVer => isMaster ? "v0.v1.v2" : "v3.v4.v5"`，业务侧直接取字符串。

---

## 8. 蓝牙连接状态机

`BleConnectState`（`lib/core/models/ble_connect_state.dart`）是整套连接流程的"协议字典"，原生 → Dart 通过 `connectStatusEC` 推送，Dart 通过 `BleConnectStateExt.label(String)` 反序列化。

### 8.1 状态列表

```
正常流程：
  none → connecting → contactDevice → searchService → searchChars
       → startBinding → connectFinish → connected
                                      └→ upgrade（OTA 时）

兼容状态：
  waitingConnect      旧版 Android 原生队列曾上报；新原生层不再主动发出。
                      如业务层需要排队，应在 Dart 集成层自行编排。

异常分支：
  disconnectByUser   主动断连
  disconnectFromSys  系统断连（设备出范围/蓝牙关闭等）
  noBleConfigFound   未找到对应 BleConfig
  emptyUuid          UUID 为空
  noDeviceFound      连接时设备已不在
  alreadyBound       已被绑定（Android 配对冲突）
  boundFail          绑定失败
  serviceFail        GATT service 发现失败
  charsFail          读写特征发现失败
  timeout            连接超时
  bleError           蓝牙错误
  systemError        系统错误
```

### 8.2 状态分组语义（`BleConnectStateExt`）

| Getter | 含义 |
| --- | --- |
| `isConnecting` | 在 `waitingConnect / connecting ~ connectFinish` 任一步；`waitingConnect` 仅兼容旧状态 |
| `isConnectFinish` | == `connectFinish` |
| `isConnected` | `connected` 或 `upgrade` |
| `isPureConnected` | 仅 `connected`（不含升级态） |
| `isDisconnected` | `none / disconnectByUser / disconnectFromSys` |
| `isDisconnectFromSys` | 系统断连 |
| `isConnectError` | `serviceFail / charsFail / timeout`（可重试错误） |
| `isError` | 更广义的失败集合（含 bound / ble / system 系列） |
| `isBound` | 仅 `alreadyBound` |
| `isUpgrade` | 仅 `upgrade` |

> **修改提示**：新增状态码必须同步三处：① 枚举本体；② `label(String)` switch；③ 各 `isXxx` getter（看是否要纳入分组）。`ConnectStateListConverter` 自动复用 `name` ↔ `label`，无需额外改 JSON 转换器。

### 8.3 业务侧的状态聚合（`BleMatchDevice`）

G1/G2 是双 BLE 设备，业务侧"整机"状态需要聚合两条腿：

- `isConnected` = 全部子设备都 `isConnected`；
- `isConnectError` = **任一**子设备出错（保守判定，便于早失败）；
- `isConnectFailed` = **全部**都失败（决定是否走重试/排障流程）；
- `isDisconnected` = 任一断开即视为断开（避免业务上把"半连接"当成功）。

改这类聚合规则时要注意：**判定边界往哪偏，会直接影响业务侧自动重连/排障弹窗触发条件**。

---

## 9. BLE 通信生命周期（完整时序）

下面是一次"App 启动 → 连接 → 发送指令 → OTA → 断开"的完整时序，能帮助理解每个 API 在协议层处于哪个阶段。

```
App 启动
  │
  ├─ EzwBle.to.bleMC.initConfigs([...])        ▶ 原生注册所有 BleConfig
  ├─ EzwBle.to.bleStateEC.listen(...)          ▶ 监听蓝牙开关/权限
  └─ EzwBle.to.bleMC.bleState()                ▶ 主动拿一次当前蓝牙状态

进入"发现页"
  │
  ├─ EzwBle.to.bleMC.startScan()
  ├─ ◀ scanResultEC: BleMatchDevice (sn = "S2025...")
  └─ EzwBle.to.bleMC.stopScan()

发起连接
  │
  ├─ EzwBle.to.bleMC.devicePreConnected(uuid)    （可选；提前告知）
  ├─ EzwBle.to.bleMC.connectDevice(belongConfig, uuid, name, sn: sn)
  │
  ├─ ◀ connectStatusEC: connecting
  ├─ ◀ connectStatusEC: contactDevice
  ├─ ◀ connectStatusEC: searchService
  ├─ ◀ connectStatusEC: searchChars
  ├─ ◀ connectStatusEC: startBinding   （仅 initiateBinding=true）
  ├─ ◀ connectStatusEC: connectFinish  + mtu
  │      （业务层此时确认应用层握手完成，比如收到 0xf5/0x11）
  ├─ EzwBle.to.bleMC.deviceConnected(uuid)     ▶ 告知原生 "业务握手 OK"
  └─ ◀ connectStatusEC: connected

通信
  ├─ EzwBle.to.bleMC.sendCmd(uuid, bytes, psType: 0)   ▶ write，等 callback
  ├─ EzwBle.to.bleMC.sendCmdNoWait(...)                ▶ Android：WRITE_TYPE_NO_RESPONSE
  │                                                       iOS：psType==1 走 OtaWriteQueue 背压
  │                                                       其它 psType 即时 WriteWithoutResponse
  └─ ◀ receiveDataEC: BleCmd(data, psType, isSuccess)

OTA 流程
  ├─ EzwBle.to.bleMC.enterUpgradeState(uuid)
  ├─ ◀ connectStatusEC: upgrade
  ├─ EzwBle.to.bleMC.sendCmdNoWait(..., psType=1)       ▶ 通过 OTA 私有服务连发
  │                                                       Android: WRITE_TYPE_NO_RESPONSE
  │                                                       iOS:     OtaWriteQueue + canSendWriteWithoutResponse 背压
  │                                                       (与 Android packets-per-event 行为对齐, 详见 IOS_OTA_NOWAIT_SPEC.md)
  ├─ （固件烧录、设备重启 → 系统断连）
  ├─ ◀ connectStatusEC: disconnectFromSys
  │      （iOS 侧 OtaWriteQueue 自动 cancelAll, 释放挂起的 await）
  ├─ （等 upgradeSwapTime ms 后重连）
  ├─ ◀ connectStatusEC: connecting ... connected
  └─ EzwBle.to.bleMC.quiteUpgradeState(uuid)

主动断开
  └─ EzwBle.to.bleMC.disconnectDevice(uuid, name, removeBond: false)
       └─ ◀ connectStatusEC: disconnectByUser
```

### 9.1 推流-调用配对清单

| 业务诉求 | 调原生 | 听原生 |
| --- | --- | --- |
| 配置一次 | `initConfigs` | — |
| 状态查询 | `bleState` | `bleStateEC` |
| 扫描 | `startScan` / `stopScan` | `scanResultEC` |
| 连接 | `connectDevice` / `devicePreConnected` / `deviceConnected` | `connectStatusEC` |
| 断连 | `disconnectDevice` | `connectStatusEC` (`disconnectByUser`) |
| 发送 | `sendCmd` / `sendCmdNoWait` | `receiveDataEC` |
| OTA | `enterUpgradeState` / `quiteUpgradeState` | `connectStatusEC` (`upgrade`) |
| 兜底 | `resetBle` / `cleanConnectCache` / `openBleSettings` / `openAppSettings` | — |

---

## 10. 错误码（BLE HCI）

`README.md` 已收录 BT Core spec 的 HCI 错误码表（0x01 - 0x45），最常见的几条业务上要识别的：

| 错误码 | 业务含义 | 通常对应 `BleConnectState` |
| --- | --- | --- |
| 0x08 | 连接超时 / 监视超时 | `timeout` / `disconnectFromSys` |
| 0x13 | 远程主动终止连接 | `disconnectFromSys` |
| 0x16 | 本地主动终止连接 | `disconnectByUser` |
| 0x22 | LMP 响应超时 | `timeout` |
| 0x3B | 连接参数不可接受 | `serviceFail` / 重连 |
| 0x3E | 同步超时 / 连接未建立 | `noDeviceFound` |

> **改原生错误码映射时**：原生侧把 HCI code 映射到 `BleConnectState` 的逻辑直接决定业务侧能看到的失败语义，调整时同步更新 README 表格。

---

## 11. 改造指引

下面这部分**不是规范，是踩坑笔记**，按改动维度列出注意事项。

### 11.1 新增一个 MethodChannel 方法

1. `flutter_ezw_ble_platform_interface.dart`：抽象签名 + `UnimplementedError`，写 dartdoc 注明参数语义；
2. `flutter_ezw_ble_method_channel.dart`：`@override`，用 `methodChannel.invokeMethod`；
3. 原生侧（外部仓库）：两端 `onMethodCall` 分支；
4. 如果新参数涉及业务模型，记得在该模型加 `customToJson()`（避免嵌套 model 走默认 toJson 导致字段缺失）。

### 11.2 新增一路 EventChannel

1. 在 `BleEventChannel` 枚举里加新值；
2. 在 `EzwBle` 单例里加一个 `Stream<XX>` 字段，包好类型转换；
3. 原生侧用相同 tag 拼接（`ezwBleTag + "_" + enum.name`）注册 StreamHandler；
4. 注意 `BleEventChannelExt._bleECs` 是 list 缓存，跨热重载可能保留旧引用——开发时 hot restart 比 hot reload 更稳。

### 11.3 改连接状态机

每加/删一个 `BleConnectState`：

1. 改枚举本体；
2. 改 `label(String)`（JSON 反序列化）；
3. 改 `BleConnectStateExt` 的所有 `isXxx`，决定它属于"连接中 / 已连 / 失败 / 断开"哪一类；
4. 检查 `BleMatchDevice` 上的聚合 getter 是否需要同步（往往要）；
5. 原生侧 push 该状态名的字符串要和 `enum.name` 完全一致。

### 11.4 改 SN / MAC 解析

- `BleSnRule.byteLength` 改成不同值时必须满足 assert，否则 `BleConfig` 构造直接抛异常；
- `BleMacRule` 只在 iOS 起作用，Android 改了等于没改；
- 替换 SN 正则时记得测控制字符的边界（默认 `[\x00-\x1F\x7F]`）。

### 11.5 关于"双腿设备"的特殊性

`BleConfig.scan.matchCount >= 2` 表示一个 SN 对应多个 BLE 端点。原生层会等到所有腿都扫描到才推 `scanResultEC`，期间业务侧不会看到"半成品"的 `BleMatchDevice`。这意味着：

- 若改 matchCount 逻辑，**要保留"组合完成才上报"的约束**，否则会破坏业务侧"以整机为单位"的假设；
- `BleMatchDevice.devices` 的顺序在 iOS / Android 上不保证一致，业务侧通过设备名里的 `_L_` / `_R_` 区分左右腿。

### 11.6 iOS OTA `WriteWithoutResponse` 背压（`sendCmdNoWait` + `psType==1`）

iOS 端 OTA 通道走单独的 per-peripheral 写队列 `OtaWriteQueue`，目标是把 packets-per-event 打满到 iOS 上限（4 包/事件），与 Android `WRITE_TYPE_NO_RESPONSE` 行为对齐。完整规范见 `IOS_OTA_NOWAIT_SPEC.md`。

关键约束（改原生侧前必读）：

- **触发条件**：仅 `sendCmdNoWait` + `psType == 1` 且特征声明 `.writeWithoutResponse` property 时启用；其它路径走原有 `WriteWithoutResponse` 即时返回，行为不变。
- **背压机制**：`pump()` 写包前检查 `peripheral.canSendWriteWithoutResponse`，命中 `false` 即暂停，等 `peripheralIsReady(toSendWriteWithoutResponse:)` 回调驱动续写。
- **软节流**：每 `softDrainEvery = 64` 包主动让出，等下一次 `peripheralIsReady`，防御老机型 `canSendWriteWithoutResponse` "报喜不报忧"。该阈值是配置常量，调参后回归测试。
- **Dart 侧同步**：`MethodChannelEzwBle.sendCmdNoWait` 已统一走 `methodChannel.invokeMethod`，**不再 fall back 到 `sendCmd`**。改 Dart 入口前先确认原生 `sendCmdNoWait` handler 仍然处理所有 `psType` 分支（OTA + 兜底）。
- **挂起 await 兜底**：断连/`reset()`/外设释放时 `OtaWriteQueue.cancelAll()` 会对所有 pending 写入回调 `result(nil)`，业务层依赖 CRC 校验决定是否 retry；改这条兜底必须保证**任何路径都不会让 Dart `await` 永远挂着**。
- **范围外**：`psType == 3`（file）通道、iOS connection interval 协商、`psType == 0`（common）write type 切换均**不在本期范围**，改动前先评估对协议层应答匹配的影响。

---

## 12. 现状与已知不足

- `pubspec.yaml` 仍写 `version: 0.0.1`，`CHANGELOG.md` 只占位。后续每次改动都应更新版本号和 changelog（语义化版本）。
- 原生侧实现不在此仓库，文档无法覆盖具体 BLE 行为（重试次数、扫描间隔等），改原生需另起一份对应文档。
- `receiveDataEC` 的 `data` 是 Base64 字符串，跨大数据（OTA）有 ~33% 体积放大，未来可考虑切到 `StandardMethodCodec` 的 `Uint8List` 通路，但会破坏当前 Dart API 的兼容性。
- `BleDeviceHardware.fromByte` 中 `isMaster = isMaster;` 是**自赋值 bug**（构造形参覆盖了字段），导致 `isMaster` 永远是字段默认值 `false`。改时记得同步更新 §7.8 的字段说明。
- `BleConnectStateExt.label` 没有覆盖 `disconnectFromSys`、`bleError`、`systemError` 三个分支，反序列化时会回落到 `BleConnectState.none`——若原生侧真的会推这些字符串，需要补全 switch。
