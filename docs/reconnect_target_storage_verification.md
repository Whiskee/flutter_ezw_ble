# iOS 回连目标相等写入验证

2026-10-08，本地工作区，未提交/推送。只修改 `BleReconnectStore.saveTargets`
的目标存储副作用，不改 App、依赖、扫描、重试、物理连接或 owner 分配。

生产链为 `activateAutoReconnectTargets` → `armReconnectTarget` →
`reconnectTasks[key] = task` → `upsert(target:)` → `saveTargets`。
业务 connected 的 `upsert(device:)` 也共用该存储边界。

`upsert` 原先将命中项移到末尾并总是 `UserDefaults.set`。正常有效列表没有
activation 顺序：activation 按调用方 batch 遍历，物理 callback/Gate 队列负责
连接优先级，persisted UUID 注册只读取身份。`target()` 使用 UUID/name 的 first
匹配，因此损坏缓存中的重复身份仍有顺序语义，不能无条件比较任意目标集合。
当前仅对原始四字段完整、有效 UUID、非空配置、UUID/非空名称无重复且完整字段值
相等的列表跳过写入，保留磁盘已有排列。四字段比较不折叠大小写。

直接读取 raw defaults，避免 `targets()` 的 compactMap 隐藏坏条目或旧字段。
比较只发生在存储末端，canonical 解析、替换设备的安全清理和新 session 安装
照常执行；独立的 security recovery 键每次更新及第五次耗尽锁存保持原样。
此处不新增定时器或进程缓存，也不扩大为通用缓存修复/目标排序。

## 行为证据

`test/ios_reconnect_store_write_test.dart` 用 `xcrun swiftc -O` 编译完整生产
`BleReconnectStore.swift`、`BleConnectionAdmissionGate.swift`、
`BleG2OtaTransactionRegistry.swift` 和生产 `armReconnectTarget/reconnectKey`
方法。harness 仅替换外部 config/peripheral 输入和 manager 的承载字段、日志出口；
`RecordingDefaults` 覆盖计数方法后仍调用真实隔离 UserDefaults suite。
这不是镜像实现、字符串匹配或真实无线连接测试。

未修改的生产 Store 首次运行同一 harness，输出
`identical upsert additionalTargetsSetCalls=1`，行为断言失败。
修复后输出 `additionalTargetsSetCalls=0`；两种初始排列下，交错批次持续通过
真实 arm 方法安装到 session 7，均 `targetsSetCalls=0 owners=2`。
初始结果为 110 个行为断言通过，覆盖：

- 完整相同目标、双腿不同批次排列及现有持久化顺序。
- 新 session 安装、旧 session 不倒退、临时 UUID 的真实 canonical 解析。
- config/UUID/name/MAC suffix 变化及大小写写回；替换身份的安全清理。
- business connected upsert 保留 MAC 提示、UUID 原子迁移、移除/config 撤销/reset。
- 缺必需字段、旧可选字段、额外键、错误字段类型/容器的实际缓存收敛。
- 重复 UUID/name 的必要写入和命中项去重，不吞 first-match 优先级。
- 第 1–5 次安全记录逐次写入，耗尽后实际 arm 拒绝，新 owner 不复活。

运行命令：

```sh
fvm flutter test --no-pub test/ios_reconnect_store_write_test.dart --reporter expanded
EZW_BLE_STORE_BASELINE=d8f546bea55789cc3670d73a7f2dba6e348ca207 fvm flutter test --no-pub test/ios_reconnect_store_write_test.dart --reporter expanded
```

第二条负证命令只从 Git 读取基线 Store 到临时编译目录，不修改生产文件。
已实际执行该负证选项，exit 1 符合预期；原输出位于本工作区
`.dart_tool/native-reconnect-store-before.txt`。`fvm flutter test --no-pub
--reporter expanded` 全量 181 项通过；新增 Dart runner 的定向 analyze 无问题，
`git diff --check` 通过。
这里统计的是 `UserDefaults.set` API 次数；物理磁盘刷写可能由系统合并，不能把
少一次 set 等同于少一次刷盘或确定节电量。未完成本改动的完整 iPhoneOS 宿主构建、
真实 BLE/SR 对照或功耗测试；宿主发布前仍须核对绑定恢复、移除和安全失败终态。
