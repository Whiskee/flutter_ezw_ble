# AGENTS.md

本文是代理在 `flutter_ezw_ble` 仓库工作的操作指南。修改代码前必须先阅读 `ARCHITECTURE.md`。

## 项目定位

`flutter_ezw_ble` 是配置驱动的 Flutter BLE 插件。Dart 侧定义 `BleConfig` 扫描/GATT 规则并暴露 MethodChannel / EventChannel API；Android 和 iOS 原生侧执行扫描、连接、GATT 写入、OTA 写入策略和事件回传。

优先阅读：

- `ARCHITECTURE.md`：插件契约、MethodChannel/EventChannel API、模型、原生职责和扩展规则。
- `IOS_OTA_NOWAIT_SPEC.md`：改 iOS OTA `WriteWithoutResponse` 行为前必须阅读。
- `README.md`：排障说明和 HCI 错误码参考。

## 关键边界

- `lib/flutter_ezw_ble.dart` 拥有 `EzwBle` 单例，并把 EventChannel stream 映射为 Dart 类型模型。
- `lib/flutter_ezw_ble_method_channel.dart` 是 Dart MethodChannel 实现。
- `lib/flutter_ezw_ble_platform_interface.dart` 定义平台 API 契约。
- `lib/flutter_ezw_ble_event_channel.dart` 定义 EventChannel 名称和缓存的 broadcast stream。
- `lib/core/models/**` 是 JSON 序列化的 BLE 配置、设备、扫描、连接、状态和命令模型。
- `android/src/main/kotlin/com/fzfstudio/ezw_ble/**` 是 Android BluetoothGatt 实现。
- `ios/Classes/**` 是 iOS CoreBluetooth 实现，包含 `BleManager`、`BleChannel` 和 `OtaWriteQueue`。

## 修改规则

- 新增 MethodChannel 方法时，同步更新 platform interface、Dart method-channel 实现、Android 分发/实现、iOS 分发/实现和测试。
- 新增 EventChannel 时，同步更新枚举、Dart stream 映射和两个平台的事件源。
- `ezwBleTag` 和 channel name 拼接规则必须与原生常量保持一致。
- `initConfigs` 必须使用 `customToJson` 序列化嵌套模型，不要改成浅层 JSON。
- 不要手工编辑 `*.g.dart`。修改源模型后运行 build_runner。
- `receiveData` 的二进制 payload 跨 Method/EventChannel 时保持 Base64 约定。
- iOS OTA 中 `psType == 1` 的 `sendCmdNoWait` 必须与 `OtaWriteQueue`、`canSendWriteWithoutResponse` 和 `IOS_OTA_NOWAIT_SPEC.md` 对齐。
- BLE 行为变化通常需要同时审视 Dart 和原生两端，不要假设 Android 与 iOS 可以共享实现细节。

## 常用命令

- `flutter analyze`：静态分析。
- `flutter test`：运行插件测试。
- `dart format lib test`：格式化 Dart 源码。
- `dart run build_runner build --delete-conflicting-outputs`：重新生成 JSON 模型输出。

使用仓库指定的 Flutter/FVM 版本。声明 channel、模型或原生 BLE 改动完成前运行最窄的相关测试；涉及共享 BLE 行为时运行 `flutter test`。

