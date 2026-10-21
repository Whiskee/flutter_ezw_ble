# Android Bond 时序验证（测试分支）

目的：拆分“系统内部 Bond 完成 → App 收到 BONDED → discoverServices”约 3 秒的等待。
这是只读观测，不是提速修复；不提前发现服务、不改变配对/Gate/超时/两腿顺序。

基线：App `202c3f461131a3ccb57507c42e2b7a411781abf1`，BLE
`3180fbc94aaee5ad3a753d86a72222e484f2e178`，even_connect
`c5f5c1253769ed5ed7712472915821a7074006d0`。它们是本次测试源码，不能证明旧压测 APK 的构建 SHA。
测试分支：`wk/2.4.0/test/261021-bond-timing-probe`。

## 构建与打开探针

当前 App `/Users/whiskee/.codex/worktrees/2a08/glasses/pubspec_overrides.yaml`
保留原来的全部 dependency_overrides，只把 BLE 换为 `../flutter_ezw_ble`。
该文件已被 Git 忽略；`pubspec.yaml` 正式引用不变。工具生成的本地 `pubspec.lock`
只有 BLE 来源改为 path，属于本地调试差异，不应提交到正式依赖。

在 App 根目录执行（当前机器使用 Homebrew JDK 21；其他机器替换为本机 JDK 21 路径）：

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./scripts/fvm flutter pub get --offline
ORG_GRADLE_PROJECT_evenTargetAbis=arm64-v8a ./scripts/fvm flutter build apk --debug --no-pub --target-platform android-arm64
```

APK：`build/app/outputs/flutter-apk/app-debug.apk`。需要覆盖安装时使用 `adb install -r`，
保留测试账号和 App 状态。安装会替换设备上的同包名 App，执行前先确认目标手机。

探针跟随现有 `Debug Mode`：native 进程默认关闭，App 的 logger 配置同步
`setDebugLoggingEnabled(true)` 后生效；需要在开始下一轮配对前打开。
Debug 构建的初始 Debug Mode 为开；内部账号可通过既有 Debug Mode 入口切换。
未看到 `BleBondTiming` 的 `probe_start`，不能把空日志解释为“没有等待”。
关闭只清诊断资源，不改变 BLE owner、广播消费或连接动作。

## 真机采集

1. 使用原压测手机、固件、账号和相同首配/解绑条件。记录 App/BLE SHA、手机 build fingerprint、
   两腿/戒指实际读回固件版本。已 Bond 的回连不能替代未 Bond 的首配样本。
2. 先开启全量日志，在另一终端跑原压测脚本，建议先每种设备 10 轮，确认探针齐全后再跑 50 轮。
   同时保留自动化的点击、弹窗观察、确认点击时间，不能把脚本找控件时间归入 BLE。
3. 覆盖一轮取消、拒绝配对、蓝牙关开、退出/重新打开 App，检查旧 probe 停止、后续新轮次使用新 probeId。
4. 开关探针各跑一小组，比较成功率和整体分布，评估 100ms 公开状态读取与额外 receiver 的观测开销。

```bash
# 保留系统 BondStateMachine、App 探针与真正业务 connected；不要只按 App PID 过滤。
adb logcat -b all -v threadtime > /tmp/bond-probe-logcat.txt
# 完成压测后 Ctrl-C，再汇总；保留原始文件以便按行回查。
python3 /Users/whiskee/.codex/worktrees/2a08/flutter_ezw_ble/tools/parse_bond_timing.py \
  /tmp/bond-probe-logcat.txt --out /tmp/bond-probe-report
```

输出 `bond_timing.csv`（每 probe 一行、单位毫秒）和 `bond_events.json`
（原始字段及输入文件/行号）。空值表示证据缺失，不填 0；两个 receiver 的先后可交换，负数差值保留。
同一窗口内重复 stage 取最早事件；需要分析重入/重复调用时回查完整 JSON。

## 时点与判据

日志 tag 为 `BleBondTiming`，正文为 JSON。每条包含 endpoint/config、session/attempt、sessionId、probeId。
耗时使用事件处冻结的 `monoNs`；`wallMs` 由同一 anchor 推导，`rawWallMs` 用于发现墙钟调整。
不能使用 Logcat 行首的写出时间替代事件时间，也不能跨重启直接相减 monotonic 值。
receiver 入口冻结当前窗口 token，并沿同步 Manager 回调链传递；取消/替换后旧入口不能归到新窗口。
Android Bond 广播本身没有物理 attempt token：新窗口建立后才首次投递的历史广播，仍无法仅靠这些字段证明其物理归属。
probeId 表示当前 endpoint 的观测窗口，不能替代 GATT/协议层的真实会话证据。

| 时点 | 证据 |
| --- | --- |
| T0：系统内部 Bond 完成 | 全量日志的 `BluetoothBondStateMachine ... BOND_BONDED`；部分系统不输出，缺失时保留未知 |
| T1：公开状态首次读到 BONDED | `public_bond_state`，`bondState=12`；后台每 100ms，只记录首次/变化，有界 15 秒 |
| T2b：后台 receiver 收到广播 | `receiver_background`，`bondState=12`；独立 HandlerThread，只记录 |
| T2m：生产 receiver 收到广播 | `receiver_main`，`bondState=12`；保留原生产线程，入口先冻结时钟 |
| T3：业务 callback 与 device monitor | `manager_entry`、`device_monitor_wait`、`device_monitor_acquired` |
| T4：服务发现锁与实际调用 | `discover_manager_wait/acquired`、`discover_call_before/after`；后者带 success/error |
| 配对请求 | `create_bond_before/after`；不增加 createBond 次数 |
| 诊断收尾 | `probe_tail`、tailMs；发现服务提交后停止 getter，最多保留 1 秒接收晚到的后台广播，仍受总 15 秒窗口限制 |
| 窗口结束 | `probe_stop`、reason；deadline/取消等不能当成连接失败事件 |

| 观察结果 | 可以支持的结论与下一步 |
| --- | --- |
| T1 明显早于 T2b/T2m，且两 receiver 接近 | App 已能读到 BONDED，广播观测仍晚；结合 T0/系统发送日志定位广播延迟。不能仅凭它确认具体 OS 定时器 |
| T2b 明显早于 T2m | 优先查生产 receiver 的主线程派发/排队；用 Perfetto 的 main Looper 和线程调度确认，不直接宣称主线程卡死 |
| T2m 早、T3 或 monitor acquired 晚 | 用入口与锁前后差值定位 App callback/锁等待；同时排除诊断日志自身耗时 |
| discover_manager_wait → acquired 很长 | 服务发现进入 Manager monitor 存在等待；结合线程栈定位锁持有者 |
| T1/T2b/T2m 都晚 | 公开 getter 没提供提前观测，不能据此推出内部 Bond 也晚，更不能据此实施轮询提速 |
| receiver/读 API 报错或 stop 缺失 | 本轮诊断证据不完整，回查权限、构建来源、Logcat 截断和窗口是否超时 |

`BluetoothDevice.getBondState()` 只表示公开 API 的观测结果，可能受系统缓存/派发影响。
100ms 是计划采样间隔，真实调度/调用耗时会扩大分辨率；探针不会调用隐藏 API 绕过缓存。
15 秒限制后续采样调度，不能中断系统正在执行的 getter；用 `readDurationNs` 识别单次读取阻塞。
后台 receiver 由 Android 的带 Handler 的注册接口派发，详见
[Context.registerReceiver 官方文档](https://developer.android.com/reference/android/content/Context#registerReceiver(android.content.BroadcastReceiver,%20android.content.IntentFilter,%20java.lang.String,%20android.os.Handler))。

## 自动化验证记录

本次新增探针核心测试 13 项，连同现有配对集成 14 项、Debug policy 4 项，共 31 项 JVM 测试通过；
汇总脚本 4 项测试通过。可在上面的 App 根目录与 JDK 21 环境复跑：

```bash
./android/gradlew -p android :flutter_ezw_ble:testDebugUnitTest \
  --tests '*BleBondTimingProbeTest' \
  --tests '*BleAndroidPairingWindowIntegrationTest' \
  --tests '*BleOtaDebugLogPolicyTest' --offline
PYTHONDONTWRITEBYTECODE=1 python3 ../flutter_ezw_ble/tools/test_parse_bond_timing.py
```

`:flutter_ezw_ble:lintAnalyzeDebug` 执行成功。分析结果中探针没有新增 API 错误；
`Runtime.context` 的静态引用有 `StaticFieldLeak` 提示，实际使用 applicationContext
（取不到时回退传入 Context），并在最后一个有界窗口结束后注销 receiver、退出线程和清除 Runtime。
既有三处 `Map.replaceAll` 的 API 24 提示不属于本次改动。
完整 `lintDebug` 未完成：既有 `flutter_plugin_android_lifecycle` 的测试依赖
`byte-buddy-1.17.7.jar` 在 Jetifier 中报 `Unsupported class file major version 68`。
这些自动化结果不能替代原压测手机的验证。

## 验收边界

第一阶段验收是能按 exact probe 串起上述时点并解释等待落在哪段，取消后无残留任务，
生产配对、发现服务和鉴权次数不增加。GATT `connectFinish` 和 BONDED 都不代表整机业务连接完成；
完整连接耗时仍以 App 真正 `logical connected` 为终点，眼镜取两腿全部完成。

当前没有实施轮询推进 GATT、提前释放 Gate、并行两腿 Bond 或协议步骤后移。
探针单测/原生编译通过也不能证明真机 3 秒延迟已定位或可稳定省掉；提速方案须基于本轮实测另行验证。
