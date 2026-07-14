package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.os.SystemClock
import com.fzfstudio.ezw_ble.ble.extension.resolveBleDeviceName
import com.fzfstudio.ezw_ble.ble.extension.toBleDevice
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Collections

/**
 * Android native 自动回连监督器。
 *
 * 该类拥有回连 task 和长期 passive `autoConnect=true` GATT。`BleManager` 只告诉它
 * “某设备已允许回连/需要取消/蓝牙关闭/连接失败”，不再关心具体调度细节。
 */
internal class BleAutoReconnectSupervisor(
    /** 当前连接设备缓存，passive GATT 回调仍需要通过这里找到 session。 */
    private val connectedDevices: MutableList<BleDevice>,
    /** 获取当前 BLE 配置；Dart 重新 initConfigs 后这里会读到最新配置。 */
    private val bleConfigs: () -> List<BleConfig>,
    /** 获取 Android BluetoothAdapter。 */
    private val bluetoothAdapter: () -> BluetoothAdapter,
    /** 获取当前 Flutter plugin context。 */
    private val context: () -> android.content.Context?,
    /** 获取 manager 当前协程作用域。 */
    private val mainScope: () -> CoroutineScope,
    /** 查询当前 Even 蓝牙状态值。 */
    private val bleState: () -> Int,
    /** 查询 Android 蓝牙是否仍可用。 */
    private val isBluetoothEnabled: () -> Boolean,
    /** 判断设备是否处于 OTA，OTA 中不做普通自动回连。 */
    private val isUpgradeDevice: (String) -> Boolean,
    /** 创建一条绑定目标 UUID 的 GATT callback。 */
    private val createConnectCallback: (String, BleConnectSource) -> BleGattSessionCallback,
    /** 提升已经进入 Gate waiting queue 的同一 session，不抢占 active。 */
    private val promotePendingAdmission: (String) -> Unit,
    /** 持久化业务确认 connected 的回连目标。 */
    private val persistReconnectTarget: (BleDevice) -> Unit,
    /** 推进连接状态，由 manager 统一清理 GATT/队列/事件。 */
    private val handleConnectState: (String, String, BleConnectState) -> Unit,
    /** 统一日志出口。 */
    private val sendLog: (BleLoggerTag, String) -> Unit,
    /**
     * 精确撤销尚未收到物理 callback 的 admission。
     *
     * deadline 只能撤销仍由相同 GATT 持有的 pre-physical session；已经进入 Gate 的
     * session 返回 false，避免把 queued GATT 当作 zombie 关闭。
     */
    private val invalidatePendingPassiveGatt: (String, BluetoothGatt) -> Boolean,
    /** 创建 passive GATT 的平台边界；测试可注入 fake 验证 autoConnect pending 次序。 */
    private val passiveGattFactory: BlePassiveGattFactory = AndroidBlePassiveGattFactory,
    /** 延迟重试调度边界；首轮 activation 永远不进入此 scheduler。 */
    attemptScheduler: BleReconnectAttemptScheduler? = null,
) {

    /** retry 与 physical deadline 共用同一可注入 scheduler，便于保持线程与测试一致。 */
    private val reconnectAttemptScheduler = attemptScheduler ?: TimerBleReconnectAttemptScheduler { attempt ->
        mainScope().launch { attempt() }
    }

    /** 首轮同步、后续防抖的统一分发器。 */
    private val attemptDispatcher = BleReconnectAttemptDispatcher(
        scheduler = reconnectAttemptScheduler,
        gattStarter = { uuid, scheduleGeneration -> beginAttempt(uuid, scheduleGeneration) },
    )

    /** 已 arm 的自动回连任务；key 使用小写 uuid，避免 Android MAC 大小写差异。 */
    private val reconnectTasks: MutableMap<String, BleReconnectTask> =
        Collections.synchronizedMap(mutableMapOf())

    /**
     * 将业务确认 connected 的设备加入 native 自动回连。
     *
     * 只有 Dart 调用 `deviceConnected` 后才应该 arm，避免 GATT ready 但业务认证失败的设备被恢复。
     */
    fun arm(
        device: BleDevice,
        source: BleConnectSource = BleConnectSource.AUTO_RECONNECT,
    ) {
        // 1. 未启用自动回连或 uuid 缺失时保持无副作用。
        val config = device.belongConfig
        if (!config.autoReconnect || device.uuid.isBlank()) {
            return
        }

        // 2. 新设备创建任务；已有任务只刷新身份和来源。
        val key = reconnectKey(device.uuid)
        val task = reconnectTasks[key]
        if (task == null) {
            reconnectTasks[key] = BleReconnectTask(
                belongConfig = config.name,
                uuid = device.uuid,
                name = device.name,
                sn = device.sn,
                source = source,
            )
        } else {
            task.name = device.name
            // source 只属于当前 attempt：manual 提升后，lifecycle/重入 activate(auto)
            // 不能在物理 callback 前把它降级；但业务 connected 后的重新 arm 必须
            // 将下一次系统断线回连复位为 autoReconnect。
            task.source = BleReconnectSourcePolicy.onArm(
                current = task.source,
                incoming = source,
                businessConnected = device.connectState.isConnected,
            )
            task.pausedByBluetoothOff = false
            // activate() 会重复进入 arm()。只有业务已确认 connected 时才算一次完整恢复，
            // disconnected 重入不得清空长离线退避或取消正在等待的 passive retry。
            if (device.connectState.isConnected) {
                task.attempt = 0
                task.consecutivePrePhysicalTimeouts = 0
                invalidateRetrySchedule(task)
                task.pendingPhysicalDeadline?.cancel()
                task.pendingPhysicalDeadline = null
            }
            // disconnected 的 arm/activate 重入只刷新 owner/source。pending GATT 必须复用；
            // 关闭再创建会制造 Android HCI register/unregister 竞态，并让手动点击打开
            // 重复 GATT；因此该分支不能取消 pending GATT 的 physical deadline。
        }

        // 3. 持久化目标供进程恢复后重建 native 回连意图。
        persistReconnectTarget(device)
        sendLog(BleLoggerTag.d, "Auto reconnect: ${device.uuid}, task armed for ${config.name}")
    }

    /** 立即建立或复用长期 pending autoConnect；物理 callback 前不发送 connecting。 */
    fun activate(device: BleDevice, source: BleConnectSource) {
        arm(device, source)
        val task = reconnectTasks[reconnectKey(device.uuid)] ?: return
        if (task.passiveGatt != null || task.timer != null) {
            if (source == BleConnectSource.MANUAL_RECONNECT) {
                promotePendingAdmission(device.uuid)
            }
            return
        }
        // 首轮不能通过 Timer(0) 异步跳出 MethodChannel：调用返回前必须已经同步执行
        // connectGatt(true)，这样上层随后启动扫描时所有有效目标都已进入系统 pending。
        beginInitialAttempt(device.uuid)
    }

    /**
     * 手动连接复用已有 autoReconnect pending GATT，并提升 Gate waiting source。
     * 返回 true 表示 manager 不得继续打开 foreground duplicate GATT。
     */
    fun promotePendingAttempt(uuid: String): Boolean {
        val task = reconnectTasks[reconnectKey(uuid)] ?: return false
        if (task.passiveGatt == null && task.timer == null) {
            return false
        }
        task.source = BleConnectSource.MANUAL_RECONNECT
        promotePendingAdmission(uuid)
        return true
    }

    /**
     * 真实 `STATE_CONNECTED` callback 到达时，取消相同 GATT 的 pending deadline。
     *
     * 保留 `passiveGatt` 作为业务 connected 后系统断连的 exact owner；只清 deadline，
     * 因而 Gate queued 的连接不会在排队期间被超时任务误杀。
     */
    @Synchronized
    fun onPassivePhysicalConnected(uuid: String, gatt: BluetoothGatt): Boolean {
        val task = reconnectTasks[reconnectKey(uuid)] ?: return false
        if (task.passiveGatt !== gatt) {
            return false
        }
        task.pendingPhysicalDeadline?.cancel()
        task.pendingPhysicalDeadline = null
        task.consecutivePrePhysicalTimeouts = 0
        invalidateRetrySchedule(task)
        val waitedMs = (SystemClock.elapsedRealtime() - task.passiveStartedAtMs).coerceAtLeast(0L)
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: $uuid, passive physical callback after ${waitedMs}ms, attempt=${task.attempt}",
        )
        return true
    }

    /**
     * 取消单个设备自动回连。
     *
     * 用户主动断开/remove 或前台连接接管同 UUID 时调用，确保 pending timer/passive
     * GATT 不再与新的 owner 竞争。
     */
    fun cancel(uuid: String, reason: String = "unspecified") {
        // 1. task 不存在时保持幂等。
        val task = reconnectTasks.remove(reconnectKey(uuid)) ?: return

        // 2. 关闭定时器和 passive GATT，避免旧回调进入当前状态机。
        task.timer?.cancel()
        task.timer = null
        task.pendingPassiveRetry = false
        task.retryScheduleGeneration = nextScheduleGeneration(task.retryScheduleGeneration)
        task.consecutivePrePhysicalTimeouts = 0
        task.pendingPhysicalDeadline?.cancel()
        task.pendingPhysicalDeadline = null
        try {
            task.passiveGatt?.disconnect()
            task.passiveGatt?.close()
        } catch (error: Exception) {
            sendLog(BleLoggerTag.e, "Auto reconnect: $uuid, close passive gatt error = ${error.message}")
        }
        task.passiveGatt = null
        task.passiveStartedAtMs = 0L
        sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, task cancelled, reason=$reason")
    }

    /**
     * 取消全部自动回连任务。
     *
     * reset/release 场景使用，防止 manager 已释放但 timer 或 passive GATT 仍回调。
     */
    fun cancelAll(reason: String = "unspecified") {
        // 1. 复制 key 列表后逐个取消，避免遍历时修改 map。
        reconnectTasks.keys.toList().forEach { key ->
            reconnectTasks[key]?.uuid?.let { cancel(it, reason = reason) }
        }
    }

    /** 返回属于指定配置的 task endpoint，供 initConfigs diff 原子构造撤权集合。 */
    @Synchronized
    fun endpointsForConfigs(configNames: Set<String>): Set<String> = reconnectTasks.values
        .filter { it.belongConfig in configNames }
        .map { it.uuid }
        .toSet()

    /** 中性 endpoint release 按稳定 UUID，必要时按非空名称命中当前 runtime task。 */
    @Synchronized
    fun endpointsMatching(uuid: String, name: String): Set<String> = reconnectTasks.values
        .filter { task ->
            (uuid.isNotBlank() && task.uuid.equals(uuid, ignoreCase = true)) ||
                (name.isNotBlank() && task.name == name)
        }
        .map { it.uuid }
        .toSet()

    /** 配置删除或关闭 autoReconnect 时，立即关闭该配置全部 passive GATT/timer。 */
    @Synchronized
    fun cancelConfigs(configNames: Set<String>, reason: String): Set<String> {
        val endpoints = endpointsForConfigs(configNames)
        endpoints.forEach { uuid -> cancel(uuid, reason) }
        return endpoints
    }

    /**
     * 蓝牙关闭时暂停所有回连任务。
     *
     * Android 蓝牙关闭会让当前 GATT binder 失效；这里只暂停，等待蓝牙恢复后继续调度。
     */
    fun pauseForBluetoothOff() {
        // 1. 清掉延迟 timer，并标记为蓝牙关闭导致的暂停。
        reconnectTasks.values.forEach { task ->
            task.pausedByBluetoothOff = true
            task.source = BleReconnectSourcePolicy.afterTransportReset()
            invalidateRetrySchedule(task)
            task.consecutivePrePhysicalTimeouts = 0
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null

            // 2. passive GATT 不可复用，必须 close 后等待下一轮重新 connectGatt。
            try {
                task.passiveGatt?.disconnect()
                task.passiveGatt?.close()
            } catch (_: Exception) {
            }
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
        }
        if (reconnectTasks.isNotEmpty()) {
            sendLog(BleLoggerTag.d, "Auto reconnect: pause ${reconnectTasks.size} task(s), bluetooth off")
        }
    }

    /**
     * 蓝牙恢复后重启被暂停的回连任务。
     *
     * 所有任务都回到 passive `connectGatt(true)`，不再使用指数退避；自动回连是业务
     * connected 后建立的持续意图，停止源只能是用户/业务主动取消、配置关闭或 reset/release。
     */
    fun resumeAfterBluetoothOn() {
        // 1. 只恢复因蓝牙关闭暂停的任务。
        reconnectTasks.values
            .filter { it.pausedByBluetoothOff }
            .forEach { task ->
                task.pausedByBluetoothOff = false
                schedule(
                    task.uuid,
                    BleConnectState.DISCONNECT_FROM_SYS,
                    preserveAttemptSource = false,
                )
            }
    }

    /**
     * 判断某个设备是否处于自动回连中的连接尝试。
     */
    fun isAttempting(uuid: String): Boolean {
        // 1. 有 task 且已经产生 attempt/passive GATT 时，认为属于自动回连上下文。
        val task = reconnectTasks[reconnectKey(uuid)] ?: return false
        return task.attempt > 0 || task.passiveGatt != null
    }

    /**
     * 根据连接失败状态调度下一次自动回连。
     *
     * 非系统/链路/GATT readiness 失败不会触发回连，避免用户主动断开后又被 native 拉起。
     */
    fun schedule(
        uuid: String,
        state: BleConnectState,
        preserveAttemptSource: Boolean = false,
        retryDelayOverrideMs: Long? = null,
        reason: String = state.toString(),
        visibilityWakeEligible: Boolean = false,
    ) {
        // 1. 非回连状态直接忽略。
        if (!shouldScheduleReconnect(state)) {
            return
        }

        // 2. 只有已经 arm 的设备才允许自动回连。
        val task = reconnectTasks[reconnectKey(uuid)] ?: return
        val config = bleConfigs().firstOrNull { it.name == task.belongConfig } ?: return

        // 3. 手动来源只覆盖当前被提升的 attempt。终态后的长期重试恢复
        //    autoReconnect；只有 activate 初始调度需要保留调用方显式 source。
        if (!preserveAttemptSource) {
            task.source = BleReconnectSourcePolicy.afterTerminalAttempt()
        }

        // 4. 配置关闭或 OTA 中不调度，避免普通回连干扰升级流程。
        if (!config.autoReconnect || isUpgradeDevice(uuid)) {
            return
        }

        // 5. 蓝牙不可用时只暂停，等待系统 powered on 后恢复。
        if (!isBluetoothEnabled() || bleState() != BLE_STATE_ON) {
            task.pausedByBluetoothOff = true
            sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, paused because bluetooth is unavailable")
            return
        }

        // 6. 新失败原因覆盖旧 timer。若失败回调来自上一轮 passive GATT，先关闭旧句柄；
        //    否则 beginAttempt 会因 passiveGatt 仍存在而跳过下一轮重建。
        invalidateRetrySchedule(task)
        task.pendingPhysicalDeadline?.cancel()
        task.pendingPhysicalDeadline = null
        if (task.passiveGatt != null) {
            try {
                task.passiveGatt?.disconnect()
                task.passiveGatt?.close()
            } catch (error: Exception) {
                sendLog(BleLoggerTag.e, "Auto reconnect: $uuid, close stale passive gatt error = ${error.message}")
            }
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
        }

        // 7. 首轮立即开始；普通终态保留 1.5s 防抖，连续 pre-physical deadline
        //    通过显式 override 自适应退避，避免长离线 register/unregister 过频。
        val delayMs = retryDelayOverrideMs ?: if (task.attempt == 0 && task.passiveGatt == null) {
            0L
        } else {
            PASSIVE_RECONNECT_DEBOUNCE_MS
        }
        val scheduleGeneration = nextScheduleGeneration(task.retryScheduleGeneration)
        task.retryScheduleGeneration = scheduleGeneration
        // 只有 pre-physical deadline 的 backoff 可被扫描命中唤醒；service/char 等
        // post-physical 失败仍按原终态节奏执行，不能被广告可见信号越权加速。
        task.pendingPassiveRetry = delayMs > 0L && visibilityWakeEligible
        task.timer = attemptDispatcher.dispatch(task.uuid, delayMs, scheduleGeneration)
        sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, schedule passive retry after ${delayMs}ms, reason=$reason")
    }

    /** activation 首轮同步创建 pending GATT，并保留调用方 source。 */
    private fun beginInitialAttempt(uuid: String) {
        val task = reconnectTasks[reconnectKey(uuid)] ?: return
        if (!isBluetoothEnabled() || bleState() != BLE_STATE_ON) {
            task.pausedByBluetoothOff = true
            return
        }
        attemptDispatcher.dispatch(uuid, 0L)
    }

    /**
     * 执行一次自动回连尝试。
     *
     * 每次尝试都使用 Android passive `connectGatt(true)`。
     */
    private fun beginAttempt(uuid: String, expectedScheduleGeneration: Long?) {
        // 1. timer 触发时 task/config 可能已取消或变化，必须重新读取。
        val task = reconnectTasks[reconnectKey(uuid)] ?: return
        if (
            expectedScheduleGeneration != null &&
            task.retryScheduleGeneration != expectedScheduleGeneration
        ) {
            return
        }
        val config = bleConfigs().firstOrNull { it.name == task.belongConfig } ?: return
        if (!config.autoReconnect) {
            return
        }

        // 2. 当前 timer 已触发，先清掉 task 里的 timer 引用；否则 passive refresh
        // 会被自己的 schedule timer 误判为“仍有等待任务”而无法重建 GATT。
        task.timer?.cancel()
        task.timer = null
        task.pendingPassiveRetry = false
        task.pendingPhysicalDeadline?.cancel()
        task.pendingPhysicalDeadline = null

        // 3. 已连接/已有 passive GATT 时不重复打开新 GATT。pending GATT 的 deadline
        //    会独立回收未收到物理 callback 的 zombie handle；Gate grant 后仍只由业务
        //    pipeline 使用 connectTimeout，不能把 queued 等待算进来。
        val currentDevice = connectedDevices.firstOrNull { it.uuid.equals(uuid, ignoreCase = true) }
        if (
            currentDevice?.connectState?.isConnected == true ||
            task.passiveGatt != null
        ) {
            sendLog(
                BleLoggerTag.d,
                "Auto reconnect: $uuid, ignored because state=${currentDevice?.connectState} passiveGatt=${task.passiveGatt != null}",
            )
            return
        }

        // 4. 蓝牙关闭期间暂停，不把这次 timer 计为失败。
        if (!isBluetoothEnabled() || bleState() != BLE_STATE_ON) {
            task.pausedByBluetoothOff = true
            return
        }

        // 5. 递增 attempt，并清理上一轮 passive GATT。attempt 只参与日志诊断，
        //    不再决定是否停止回连，避免设备离开较久后 native 主动放弃。
        task.attempt = nextAttemptCount(task.attempt)
        task.passiveGatt?.close()
        task.passiveGatt = null
        task.passiveStartedAtMs = 0L

        // 6. 新回连契约统一使用 passive autoConnect，不再由旧配置开关退回扫描/主动连接。
        beginPassiveReconnect(task, config)
    }

    /**
     * 启动 Android native passive autoConnect。
     *
     * passive 只恢复物理链路；连接成功后仍会进入同一套 service/char/notify 初始化。
     */
    private fun beginPassiveReconnect(task: BleReconnectTask, config: BleConfig) {
        // 1. 通过已知 address 构造 BluetoothDevice；真正连接由 Android 协议栈等待设备出现。
        val remoteDevice = bluetoothAdapter().getRemoteDevice(task.uuid)
        val cachedDevice = connectedDevices.firstOrNull { it.uuid.equals(task.uuid, ignoreCase = true) }
        val resolvedName = resolveBleDeviceName(remoteDevice.name, task.name, cachedDevice?.name)

        // 2. 没有稳定 name 时不能进入 GATT，否则状态/日志无法匹配业务设备。
        if (resolvedName == null) {
            sendLog(BleLoggerTag.e, "Auto reconnect: ${task.uuid}, passive skipped, device name missing")
            schedule(task.uuid, BleConnectState.NO_DEVICE_FOUND)
            return
        }

        // 3. 没有设备缓存时补建，后续 GATT callback 仍通过 connectedDevices 找 session。
        var bleDevice = cachedDevice
        if (bleDevice == null) {
            bleDevice = remoteDevice.toBleDevice(config, resolvedName, task.sn, 0)
            connectedDevices.add(bleDevice)
        }

        // 4. 自动路径在真实 STATE_CONNECTED callback 前不发用户可见 connecting。
        val callback = createConnectCallback(task.uuid, task.source)

        // 5. 关键：autoConnect=true 让系统在设备回来时恢复物理链路。
        val gatt = passiveGattFactory.connect(remoteDevice, context(), callback)

        // 6. 系统未创建 GATT session 时，按 timeout 进入下一轮调度。
        if (gatt == null) {
            sendLog(BleLoggerTag.e, "Auto reconnect: ${task.uuid}, passive connectGatt returned null")
            schedule(task.uuid, BleConnectState.TIMEOUT)
            return
        }

        // 7. 保存 passive GATT 并只监控“尚未收到 STATE_CONNECTED”的阶段。deadline
        //    到期不会上报 Dart timeout 或停掉长期 intent，而是 exact close + 自适应退避重建。
        bleDevice.update(gatt)
        task.passiveGatt = gatt
        task.passiveStartedAtMs = SystemClock.elapsedRealtime()
        startPendingPhysicalDeadline(task, config, gatt)
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: ${task.uuid}, passive attempt ${task.attempt} started, physicalDeadline=${pendingPhysicalDeadlineMs(config)}ms",
        )
    }

    /**
     * 为 exact passive GATT 设置物理连接前 deadline。
     *
     * Android `autoConnect=true` 在部分系统版本可能长期不返回 callback。deadline 到期时
     * 先让 manager 以 GATT identity 撤销 pre-physical admission，随后才清 task 并延迟重建；
     * 这样迟到 callback 无法进入新 generation，且不会影响已经进入 Gate 的 session。
     */
    private fun startPendingPhysicalDeadline(
        task: BleReconnectTask,
        config: BleConfig,
        gatt: BluetoothGatt,
    ) {
        task.pendingPhysicalDeadline?.cancel()
        val deadlineMs = pendingPhysicalDeadlineMs(config)
        task.pendingPhysicalDeadline = reconnectAttemptScheduler.schedule(deadlineMs) {
            onPendingPhysicalDeadline(task.uuid, gatt, deadlineMs)
        }
    }

    /** deadline identity 检查与清理由 supervisor 串行，但 manager 回调期间不能持有该锁。 */
    private fun onPendingPhysicalDeadline(uuid: String, expectedGatt: BluetoothGatt, deadlineMs: Long) {
        synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return
            if (task.passiveGatt !== expectedGatt || task.pendingPhysicalDeadline == null) {
                return
            }
        }

        // manager 会检查 exact device/GATT/admission；若物理 callback 已经进入 Gate，
        // 此处返回 false，deadline 只失效自身，绝不触碰 queued session。manager 调用必须
        // 在 supervisor monitor 外执行，避免 physical callback 的 manager→supervisor 反向锁序。
        if (!invalidatePendingPassiveGatt(uuid, expectedGatt)) {
            return
        }

        val (timeoutCount, retryDelayMs) = synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return
            if (task.passiveGatt !== expectedGatt || task.pendingPhysicalDeadline == null) {
                return
            }
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
            task.consecutivePrePhysicalTimeouts = nextAttemptCount(task.consecutivePrePhysicalTimeouts)
            val timeoutCount = task.consecutivePrePhysicalTimeouts
            timeoutCount to BlePassiveReconnectDelayPolicy
                .delayAfterConsecutivePrePhysicalTimeouts(timeoutCount)
        }
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: $uuid, passive deadline ${deadlineMs}ms reached, consecutive=$timeoutCount, rebuild after ${retryDelayMs}ms",
        )
        // 不经 handleConnectState(TIMEOUT)：这只是 native passive handle 的后台刷新，
        // 不能停止 autoReconnect 或触发 Dart/UI 的一次性超时展示。
        schedule(
            uuid,
            BleConnectState.TIMEOUT,
            retryDelayOverrideMs = retryDelayMs,
            reason = "prePhysicalDeadline#$timeoutCount",
            visibilityWakeEligible = true,
        )
    }

    /**
     * 扫描重新看到目标时，只唤醒 exact pre-physical owner 或它的 pending retry。
     *
     * 已物理连接/Gate queued、用户取消、蓝牙关闭均返回 false；唤醒后仍使用同一个
     * `connectGatt(true)` 管线，不创建 foreground 第二 owner，也不触发 Dart/UI timeout。
     */
    fun notifyTargetVisible(uuid: String, name: String): Boolean {
        var expectedGatt: BluetoothGatt? = null
        val pendingRetryWake = synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return false
            val config = bleConfigs().firstOrNull { it.name == task.belongConfig } ?: return false
            if (
                !config.autoReconnect ||
                task.pausedByBluetoothOff ||
                !isBluetoothEnabled() ||
                bleState() != BLE_STATE_ON ||
                isUpgradeDevice(uuid)
            ) {
                return false
            }

            val exactGatt = task.passiveGatt
            val hasPrePhysicalGatt = exactGatt != null && task.pendingPhysicalDeadline != null
            val hasPendingRetry = exactGatt == null && task.timer != null && task.pendingPassiveRetry
            if (!hasPrePhysicalGatt && !hasPendingRetry) {
                return false
            }

            if (hasPendingRetry) {
                prepareTargetVisibleWake(task, name)
                true
            } else {
                expectedGatt = exactGatt
                false
            }
        }
        if (pendingRetryWake) {
            // 调度放在 supervisor monitor 外；用户 cancel 与本次 wake 竞争时由 task
            // identity 自然 fail closed，且不会把锁带入 Timer/GATT 创建路径。
            scheduleTargetVisibleWake(uuid)
            return true
        }

        val exactGatt = expectedGatt ?: return false
        // manager 调用期间不持有 supervisor monitor，避免与 physical callback 的
        // manager→supervisor 顺序形成锁反转；manager 仍会拒绝已进入 Gate 的 exact GATT。
        if (!invalidatePendingPassiveGatt(uuid, exactGatt)) {
            return false
        }

        val clearedExactGatt = synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return false
            if (task.passiveGatt !== exactGatt || task.pendingPhysicalDeadline == null) {
                return false
            }
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
            prepareTargetVisibleWake(task, name)
            true
        }
        if (!clearedExactGatt) {
            return false
        }
        // 与 deadline 路径一致，schedule 不持 supervisor monitor，保持单向锁序。
        scheduleTargetVisibleWake(uuid)
        return true
    }

    /** 在 supervisor 锁内重置可见目标的长离线计数与旧重试代际。 */
    private fun prepareTargetVisibleWake(task: BleReconnectTask, name: String) {
        invalidateRetrySchedule(task)
        if (name.isNotBlank()) {
            task.name = name
        }
        task.consecutivePrePhysicalTimeouts = 0
    }

    /** 可见唤醒仍走原 passive 调度器；250ms 防抖不会产生 foreground owner。 */
    private fun scheduleTargetVisibleWake(uuid: String) {
        schedule(
            uuid,
            BleConnectState.TIMEOUT,
            preserveAttemptSource = true,
            retryDelayOverrideMs = BlePassiveReconnectDelayPolicy.VISIBLE_WAKE_DEBOUNCE_MS,
            reason = "targetVisible",
        )
        sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, target visible, wake passive retry")
    }

    /** config 以毫秒表达；异常值仍至少保留 1 秒，避免 0ms 注册/关闭风暴。 */
    private fun pendingPhysicalDeadlineMs(config: BleConfig): Long =
        config.connectTimeout.toLong().coerceAtLeast(MIN_PENDING_PHYSICAL_DEADLINE_MS)

    /**
     * 判断连接状态是否允许自动回连。
     */
    private fun shouldScheduleReconnect(state: BleConnectState): Boolean =
        state == BleConnectState.DISCONNECT_FROM_SYS ||
            state == BleConnectState.TIMEOUT ||
            state == BleConnectState.SERVICE_FAIL ||
            state == BleConnectState.CHARS_FAIL ||
            state == BleConnectState.NO_DEVICE_FOUND

    /** 取消旧 retry 并推进代际，避免已取消 Timer 的迟到 callback 启动新 GATT。 */
    private fun invalidateRetrySchedule(task: BleReconnectTask) {
        task.timer?.cancel()
        task.timer = null
        task.pendingPassiveRetry = false
        task.retryScheduleGeneration = nextScheduleGeneration(task.retryScheduleGeneration)
    }

    private companion object {
        /** Even 插件内部的蓝牙开启状态值。 */
        private const val BLE_STATE_ON = 5

        /** 非 deadline 终态重建的基础防抖；deadline 自身使用自适应策略。 */
        private const val PASSIVE_RECONNECT_DEBOUNCE_MS = 1500L

        /** physical callback 前 deadline 的安全下限。 */
        private const val MIN_PENDING_PHYSICAL_DEADLINE_MS = 1000L

        /** 统一 uuid key，规避 MAC 大小写差异。 */
        private fun reconnectKey(uuid: String): String = uuid.lowercase()

        /**
         * 计算下一次尝试序号。
         *
         * 自动回连可能持续很久，序号只用于日志；达到 Int 上限后保持饱和，
         * 避免极端长期运行时溢出成负数并破坏 Timer 延迟。
         */
        private fun nextAttemptCount(current: Int): Int =
            if (current == Int.MAX_VALUE) Int.MAX_VALUE else current + 1

        /** retry generation 只用于 identity；溢出时回到 1，0 保留给初始状态。 */
        private fun nextScheduleGeneration(current: Long): Long =
            if (current == Long.MAX_VALUE) 1L else current + 1L
    }
}
