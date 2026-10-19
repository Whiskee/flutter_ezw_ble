# Android OTA 成功逐包日志减负验证

日期：2026-10-19。插件基线为 `042c23a2dcadf034f93df6a31a4f430e329e152a`，使用 App `dev/v2.3.3` 的锁定依赖验证。

## 改动与不变量

生产入口为 `sendCmdNoWait(psType=1)` → `BleAndroidOtaWriteQueue.enqueue/pump` → `BluetoothGatt.writeCharacteristic` → `BleGattSessionCallback.onCharacteristicWrite` → manager 的 exact owner 分发 → 队列完成。原逻辑每个正常 OTA 包产生队列 `enqueued/submitted/completed` 三条与成功 GATT callback 一条详情。

`BleOtaDebugLogPolicy` 进程内默认关闭，仅由既有 `setDebugLoggingEnabled(bool)` 同步宿主 Debug 设置；没有 build 或线上/本地差异。setter 只写 volatile policy，不访问 `BleManager.instance`、创建蓝牙资源或更改 Trace。inline lazy helper 在成功逐包字符串插值和 logger 调用前返回。

接收入口 `BleGattSessionCallback.onCharacteristicChanged` 先按原路径完成 `emitReceiveData`，再决定是否构造已识别 `psType=1` 的成功接收元数据。Base64 payload、exact physical owner、session/attempt、事务身份和解析顺序均保持原样，门控不包围业务分发。

失败 callback、未知/非 OTA 通道、同步拒绝、BUSY 背压、stall、取消、旧 callback drain、空对象和未知 read UUID 错误继续记录。阶段与事务日志、全局 `sendLog`、native/Dart 日志桥及 iOS 实现未改变；提交、包内容、owner/generation、watchdog/重试、callback 和 Future 完成均不受门控控制。

## 受控自动化回归

独立 Gradle runner 编译本仓全部 Android Kotlin，环境为 JDK 17 / Gradle 8.11.1 / AGP 8.5.2 / Kotlin 2.1.10。`flutter_ezw_utils` 使用 App 锁定的 `53ef9f052653b8b7c9ffacce20ee2ad88e5ef7ed`。runner 在仓库外提供宿主通常注入的 Flutter embedding、coroutines 和 JUnit 5 engine，没有修改仓库构建或依赖声明。Android framework 使用 AGP mockable stubs，实际 GATT callback 与 OTA 队列使用生产类，蓝牙边界由 Mockito 代替。

- 修复前，同一千包队列与千次实际写 callback 的日志数量断言失败，其余行为断言通过；正常完成仍分别产生 3,000 条队列和 1,000 条 callback 详情。
- 初始日志修复后，Debug 全量 146 项、Release 定向 17 项通过。真实 OTA 随后发现成功接收元数据仍有输出，因此补齐接收门控。
- 接收回归修复前 4 项中 2 项失败，修复后 4/4 通过；数据断言均在日志断言之前执行，负证同时证明旧实现数据仍完整。
- 最终版本 Debug 全量 **151/151**、Release 定向 **22/22** 通过，均无跳过。千包提交、千次写 callback、千次 notify 均保留完整数据与完成数，成功详情分别从 3,000 / 1,000 / 1,000 条降至 0。
- 关闭路径 20,000 次 packet/write helper 和 10,000 次 receive helper 调用均不求值消息、不调用 logger。实际接收 callback 普通模式仅保留业务所需的一次 payload 读取，不访问日志专用 `writeType` 或第二次 `value.size`。
- 同一对象普通 → Debug → 普通热切时，三份接收事件 Map 完全相同；开启恢复原日志格式，关闭立即生效，不补发。非 OTA type 0/2、未知通道、空对象、未知 UUID、失败、拒绝、背压、stall、取消、drain 和原有 exact owner/watchdog/transaction 回归均通过。

完整 Debug 命令模板如下，`<gradle>` 指定 Gradle 8.11.1 可执行文件，`<validation-runner>` 指上述具有锁定宿主依赖和 JVM 测试环境的外部 runner。原始输出、结果 XML 与红绿对照保留在测试工作区，不作为本仓可点击链接。

```text
<gradle> -p <validation-runner> :flutter_ezw_ble:testDebugUnitTest --console plain
```

## 后续最终 Release 真机结果

宿主以相同 233 基线、锁定依赖和本插件构建完整 arm64 Release/R8 包，在 Samsung SM-A376B / Android 16 上完成真实双腿 OTA。

初始 A 包完成 `2.3.2.14 → 2.3.2.10`，两腿各 6 组件成功，但仍有 2,328 条成功接收元数据；这正是补充接收门控的实际依据。最终 B 包完成 `2.3.2.10 → 2.3.2.14`，两腿各 6 组件成功、payload 9,401,880 bytes，队列三阶段、成功写 callback 和成功接收元数据详情均为 **0**；Dart RAW/mini/成功 ACK 详情也为 0，控制阶段和 128 条粗进度保留。

重启窗保留 4W / 2E 后双腿恢复业务连接。随后新的配置 request/response 和 fresh preflight 实读左右均为 `2.3.2.14`；同版本读取跳过传输，没有建立第二个 native OTA 事务。App 的同名日期记录 `docs/ota/2026-10-19-android-ota-log-reduction.md` 保存跨仓集成、窗口口径与更多宿主验证结果。

JVM 回归和真机结果须分别理解：前者覆盖可控失败、取消与数据不变量，后者只有最终 B 一轮完整双腿样本；没有进行真实硬件失败注入。A/B 使用不同真实固件，不能据耗时差推导性能收益。本地 Release 沿 pinned logger 未配置公钥时的既有明文 fallback，**线上加密日志出口及 Android 系统功耗 A/B 尚未验证**，不据日志条数宣称整机节电比例或持续高耗电全部解决。
