package com.fzfstudio.ezw_ble.ble

import BleLoggerTag
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.os.Build
import com.fzfstudio.ezw_ble.ble.extension.resolveBleDeviceName
import com.fzfstudio.ezw_ble.ble.extension.toBleDevice
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Collections
import java.util.Timer
import java.util.TimerTask

/**
 * Android native 自动回连监督器。
 *
 * 该类拥有回连 task、backoff、passive `autoConnect=true` 和 watchdog。`BleManager` 只告诉它
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
    private val createConnectCallback: (String) -> BleGattSessionCallback,
    /** 持久化业务确认 connected 的回连目标。 */
    private val persistReconnectTarget: (BleDevice) -> Unit,
    /** 推进连接状态，由 manager 统一清理 GATT/队列/事件。 */
    private val handleConnectState: (String, String, BleConnectState) -> Unit,
    /** 主动回连时复用 manager 的前台 connect 路由。 */
    private val activeConnect: (BleReconnectTask) -> Unit,
    /** 统一日志出口。 */
    private val sendLog: (BleLoggerTag, String) -> Unit,
) {

    /** 已 arm 的自动回连任务；key 使用小写 uuid，避免 Android MAC 大小写差异。 */
    private val reconnectTasks: MutableMap<String, BleReconnectTask> =
        Collections.synchronizedMap(mutableMapOf())

    /**
     * 将业务确认 connected 的设备加入 native 自动回连。
     *
     * 只有 Dart 调用 `deviceConnected` 后才应该 arm，避免 GATT ready 但业务认证失败的设备被恢复。
     */
    fun arm(device: BleDevice) {
        // 1. 未启用自动回连或 uuid 缺失时保持无副作用。
        val config = device.belongConfig
        if (!config.autoReconnect || device.uuid.isBlank()) {
            return
        }

        // 2. 新设备创建任务；已有任务刷新身份并释放 watchdog/passive handle 所有权。
        val key = reconnectKey(device.uuid)
        val task = reconnectTasks[key]
        if (task == null) {
            reconnectTasks[key] = BleReconnectTask(
                belongConfig = config.name,
                uuid = device.uuid,
                name = device.name,
                sn = device.sn,
            )
        } else {
            task.name = device.name
            task.attempt = 0
            task.pausedByBluetoothOff = false
            task.timer?.cancel()
            task.timer = null
            // 业务 connected 可能正是由 passive autoConnect 的 GATT 达成。
            // 这时 task.passiveGatt 与 device.myGatt 是同一个 live session；
            // 如果在 arm 阶段 close 它，Dart 已收到 connected，但系统 GATT 会立刻断开，
            // 后续写命令全部变成 "write start failed" 的假连接。
            val passiveGatt = task.passiveGatt
            val passiveGattIsLiveConnection =
                passiveGatt != null &&
                    passiveGatt == device.myGatt &&
                    device.connectState.isConnected
            if (passiveGatt != null && !passiveGattIsLiveConnection) {
                passiveGatt.close()
            }
            task.passiveGatt = null
        }

        // 3. 持久化目标供进程恢复后重建 native 回连意图。
        persistReconnectTarget(device)
        sendLog(BleLoggerTag.d, "Auto reconnect: ${device.uuid}, task armed for ${config.name}")
    }

    /**
     * 取消单个设备自动回连。
     *
     * 用户主动断开/remove 时必须调用，确保 pending timer/passive GATT 不再恢复连接。
     */
    fun cancel(uuid: String) {
        // 1. task 不存在时保持幂等。
        val task = reconnectTasks.remove(reconnectKey(uuid)) ?: return

        // 2. 关闭定时器和 passive GATT，避免旧回调进入当前状态机。
        task.timer?.cancel()
        task.timer = null
        try {
            task.passiveGatt?.disconnect()
            task.passiveGatt?.close()
        } catch (error: Exception) {
            sendLog(BleLoggerTag.e, "Auto reconnect: $uuid, close passive gatt error = ${error.message}")
        }
        task.passiveGatt = null
        sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, task cancelled")
    }

    /**
     * 取消全部自动回连任务。
     *
     * reset/release 场景使用，防止 manager 已释放但 timer 或 passive GATT 仍回调。
     */
    fun cancelAll() {
        // 1. 复制 key 列表后逐个取消，避免遍历时修改 map。
        reconnectTasks.keys.toList().forEach { key ->
            reconnectTasks[key]?.uuid?.let { cancel(it) }
        }
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
            task.timer?.cancel()
            task.timer = null

            // 2. passive GATT 不可复用，必须 close 后等待下一轮重新 connectGatt。
            try {
                task.passiveGatt?.disconnect()
                task.passiveGatt?.close()
            } catch (_: Exception) {
            }
            task.passiveGatt = null
        }
        if (reconnectTasks.isNotEmpty()) {
            sendLog(BleLoggerTag.d, "Auto reconnect: pause ${reconnectTasks.size} task(s), bluetooth off")
        }
    }

    /**
     * 蓝牙恢复后重启被暂停的回连任务。
     *
     * 所有任务都回到 `schedule`，统一遵守 backoff，而不是立即并发连接。
     * maxAttempts 不能作为停止条件；自动回连是业务 connected 后建立的持续意图。
     */
    fun resumeAfterBluetoothOn() {
        // 1. 只恢复因蓝牙关闭暂停的任务。
        reconnectTasks.values
            .filter { it.pausedByBluetoothOff }
            .forEach { task ->
                task.pausedByBluetoothOff = false
                schedule(task.uuid, BleConnectState.DISCONNECT_FROM_SYS)
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
    fun schedule(uuid: String, state: BleConnectState, overrideDelayMs: Long? = null) {
        // 1. 非回连状态直接忽略。
        if (!shouldScheduleReconnect(state)) {
            return
        }

        // 2. 只有已经 arm 的设备才允许自动回连。
        val task = reconnectTasks[reconnectKey(uuid)] ?: return
        val config = bleConfigs().firstOrNull { it.name == task.belongConfig } ?: return

        // 3. 配置关闭或 OTA 中不调度，避免普通回连干扰升级流程。
        if (!config.autoReconnect || isUpgradeDevice(uuid)) {
            return
        }

        // 4. 蓝牙不可用时只暂停，等待系统 powered on 后恢复。
        if (!isBluetoothEnabled() || bleState() != BLE_STATE_ON) {
            task.pausedByBluetoothOff = true
            sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, paused because bluetooth is unavailable")
            return
        }

        // 5. 新失败原因覆盖旧 timer。即使尝试次数已经超过历史 maxAttempts，也不能停止；
        //    自动回连的停止源只能是用户/业务主动取消、配置关闭、reset/release 或进程死亡。
        task.timer?.cancel()
        val nextAttempt = nextAttemptCount(task.attempt)
        val delayMs = overrideDelayMs ?: calculateDelay(config, nextAttempt)
        val timer = Timer()
        task.timer = timer
        timer.schedule(object : TimerTask() {
            override fun run() {
                mainScope().launch {
                    beginAttempt(task.uuid, state)
                }
            }
        }, delayMs)
        sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, schedule attempt $nextAttempt after ${delayMs}ms, reason=$state")
    }

    /**
     * 执行一次自动回连尝试。
     *
     * 主动尝试复用 manager 的 connect；passive 尝试使用 Android `autoConnect=true`。
     */
    private fun beginAttempt(uuid: String, previousState: BleConnectState) {
        // 1. timer 触发时 task/config 可能已取消或变化，必须重新读取。
        val task = reconnectTasks[reconnectKey(uuid)] ?: return
        val config = bleConfigs().firstOrNull { it.name == task.belongConfig } ?: return
        if (!config.autoReconnect) {
            return
        }

        // 2. 当前 timer 已触发，先清掉 task 里的 timer 引用；否则 passive refresh
        // 会被自己的 schedule timer 误判为“仍有等待任务”而无法重建 GATT。
        task.timer?.cancel()
        task.timer = null

        // 3. 已连接/正在连接/已有 passive GATT 时不重复打开新 GATT。
        // passive watchdog 会关闭僵死 GATT，但 UI 仍保持 CONNECTING；此时允许
        // TIMEOUT 原因进入下一轮，重建底层 passive handle。
        val currentDevice = connectedDevices.firstOrNull { it.uuid.equals(uuid, ignoreCase = true) }
        val isPassiveRefresh =
            previousState == BleConnectState.TIMEOUT &&
                currentDevice?.connectState?.isFlowConnecting == true &&
                task.passiveGatt == null
        if (
            (currentDevice?.connectState?.isFlowConnecting == true && !isPassiveRefresh) ||
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

        // 5. 递增 attempt，并清理上一轮 passive GATT。attempt 只参与退避计算和日志诊断，
        //    不再决定是否停止回连，避免设备离开较久后 native 主动放弃。
        task.attempt = nextAttemptCount(task.attempt)
        task.passiveGatt?.close()
        task.passiveGatt = null

        // 6. 系统断连/扫描找不到/多次失败后使用 passive autoConnect。
        //
        // autoReconnect 已经拥有稳定 address，不应该再显式 startScan；系统断连场景交给
        // Android `connectGatt(autoConnect=true)` 持有底层 rendezvous point。
        val usePassive = config.autoReconnectUseNativePassive &&
            (previousState == BleConnectState.DISCONNECT_FROM_SYS ||
                previousState == BleConnectState.NO_DEVICE_FOUND ||
                task.attempt > 1)
        if (usePassive) {
            beginPassiveReconnect(task, config)
            return
        }

        // 7. 主动回连复用 manager 的完整连接路由和 GATT readiness。
        sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, active attempt ${task.attempt}")
        activeConnect(task)
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

        // 4. 先上报 connecting，避免 passive pending 时 UI 仍显示可点击断开态。
        handleConnectState(task.uuid, resolvedName, BleConnectState.CONNECTING)
        val callback = createConnectCallback(task.uuid)

        // 5. 关键：autoConnect=true 让系统在设备回来时恢复物理链路。
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            remoteDevice.connectGatt(context(), true, callback, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_2M)
        } else {
            remoteDevice.connectGatt(context(), true, callback)
        }

        // 6. 系统未创建 GATT session 时，按 timeout 进入下一轮调度。
        if (gatt == null) {
            sendLog(BleLoggerTag.e, "Auto reconnect: ${task.uuid}, passive connectGatt returned null")
            // CONNECTING 已经发给 Dart；autoReconnect 未取消前 UI 继续保持连接中，
            // 下一轮由 beginAttempt 的 passive refresh 分支重建底层 handle。
            schedule(task.uuid, BleConnectState.TIMEOUT)
            return
        }

        // 7. 保存 passive GATT 并启动 watchdog，防止 autoConnect 永久无回调。
        bleDevice.update(gatt)
        task.passiveGatt = gatt
        startPassiveWatchdog(task, config)
        sendLog(BleLoggerTag.d, "Auto reconnect: ${task.uuid}, passive attempt ${task.attempt} started")
    }

    /**
     * 为 passive autoConnect 建立 watchdog。
     *
     * Android `autoConnect=true` 可能长期 pending 且不回调；watchdog 负责关闭僵尸 GATT 并重试。
     */
    private fun startPassiveWatchdog(task: BleReconnectTask, config: BleConfig) {
        // 1. 同一 task 只保留一个 watchdog。
        task.timer?.cancel()
        val timer = Timer()
        task.timer = timer

        // 2. passive pending 不是前台连接超时；它的目标是持续刷新底层 autoConnect 句柄。
        // 这里使用短周期，避免设备回到手机附近后还卡在 30s attempt 退避窗口。
        val watchdogMs = PASSIVE_REFRESH_WATCHDOG_MS
            .coerceAtLeast(config.autoReconnectBaseDelayMs.toLong())
            .coerceAtMost(config.autoReconnectMaxDelayMs.toLong())
        timer.schedule(object : TimerTask() {
            override fun run() {
                mainScope().launch {
                    // 3. timer 触发时目标可能已取消，必须重新读取。
                    val current = reconnectTasks[reconnectKey(task.uuid)] ?: return@launch
                    val device = connectedDevices.firstOrNull { it.uuid.equals(task.uuid, ignoreCase = true) }

                    // 4. 已连接则 watchdog 不再改变状态。
                    if (device?.connectState?.isConnected == true) {
                        return@launch
                    }

                    // 5. 关闭 pending passive GATT，避免下一轮叠加旧 session。
                    try {
                        current.passiveGatt?.disconnect()
                        current.passiveGatt?.close()
                    } catch (_: Exception) {
                    }
                    current.passiveGatt = null
                    current.timer = null

                    // 6. watchdog 只刷新底层 passive handle，不向 Dart/UI 推 TIMEOUT。
                    // autoReconnect 的可见语义保持为“持续连接中”，直到用户取消或真实连接成功。
                    sendLog(BleLoggerTag.d, "Auto reconnect: ${task.uuid}, passive watchdog refresh")
                    schedule(task.uuid, BleConnectState.TIMEOUT, PASSIVE_REFRESH_RETRY_DELAY_MS)
                }
            }
        }, watchdogMs)
    }

    /**
     * 判断连接状态是否允许自动回连。
     */
    private fun shouldScheduleReconnect(state: BleConnectState): Boolean =
        state == BleConnectState.DISCONNECT_FROM_SYS ||
            state == BleConnectState.TIMEOUT ||
            state == BleConnectState.SERVICE_FAIL ||
            state == BleConnectState.CHARS_FAIL ||
            state == BleConnectState.NO_DEVICE_FOUND

    /**
     * 计算 backoff 延迟。
     */
    private fun calculateDelay(config: BleConfig, attempt: Int): Long {
        // 1. 策略下沉到独立 policy，便于测试和替换。
        return BleAutoReconnectDelayPolicy.calculate(
            baseMs = config.autoReconnectBaseDelayMs,
            maxMs = config.autoReconnectMaxDelayMs,
            attempt = attempt,
        )
    }

    private companion object {
        /** Even 插件内部的蓝牙开启状态值。 */
        private const val BLE_STATE_ON = 5

        /** passive autoConnect 僵住时的刷新周期；短周期保证设备回到附近后能快速重建 GATT。 */
        private const val PASSIVE_REFRESH_WATCHDOG_MS = 5000L

        /** watchdog 关闭旧 passive GATT 后的重试延迟，和指数退避解耦。 */
        private const val PASSIVE_REFRESH_RETRY_DELAY_MS = 1000L

        /** 统一 uuid key，规避 MAC 大小写差异。 */
        private fun reconnectKey(uuid: String): String = uuid.lowercase()

        /**
         * 计算下一次尝试序号。
         *
         * 自动回连可能持续很久，序号只用于日志和指数退避；达到 Int 上限后保持饱和，
         * 避免极端长期运行时溢出成负数并破坏 Timer 延迟。
         */
        private fun nextAttemptCount(current: Int): Int =
            if (current == Int.MAX_VALUE) Int.MAX_VALUE else current + 1
    }
}
