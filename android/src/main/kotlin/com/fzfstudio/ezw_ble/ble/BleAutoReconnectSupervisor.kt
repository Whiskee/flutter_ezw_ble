package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.os.Build
import com.fzfstudio.ezw_ble.ble.extension.resolveBleDeviceName
import com.fzfstudio.ezw_ble.ble.extension.toBleDevice
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Collections
import java.util.Timer
import java.util.TimerTask

/**
 * Android native 自动回连监督器。
 *
 * 该类拥有回连 task、passive `autoConnect=true` 和 watchdog。`BleManager` 只告诉它
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
     * 用户主动断开/remove 或前台连接接管同 UUID 时调用，确保 pending timer/passive
     * GATT 不再与新的 owner 竞争。
     */
    fun cancel(uuid: String, reason: String = "unspecified") {
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

    /**
     * 蓝牙关闭时暂停所有回连任务。
     *
     * Android 蓝牙关闭会让当前 GATT binder 失效；这里只暂停，等待宿主的 scan-first
     * 前台连接按 UUID 接管，避免蓝牙恢复瞬间的 passive GATT 抢占扫描编排。
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
    fun schedule(uuid: String, state: BleConnectState) {
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

        // 5. 新失败原因覆盖旧 timer。若失败回调来自上一轮 passive GATT，先关闭旧句柄；
        //    否则 beginAttempt 会因 passiveGatt 仍存在而跳过下一轮重建。
        task.timer?.cancel()
        if (task.passiveGatt != null) {
            try {
                task.passiveGatt?.disconnect()
                task.passiveGatt?.close()
            } catch (error: Exception) {
                sendLog(BleLoggerTag.e, "Auto reconnect: $uuid, close stale passive gatt error = ${error.message}")
            }
            task.passiveGatt = null
        }

        // 6. 自动回连不再做指数退避：首轮立即开始；后续重建旧 passive GATT
        //    时使用 1.5s 固定防抖，兼顾回连速度和 register/unregister 过频风险。
        val delayMs =
            if (task.attempt == 0 && task.passiveGatt == null) 0L
            else PASSIVE_RECONNECT_DEBOUNCE_MS
        val timer = Timer()
        task.timer = timer
        timer.schedule(object : TimerTask() {
            override fun run() {
                mainScope().launch {
                    beginAttempt(task.uuid)
                }
            }
        }, delayMs)
        sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, schedule passive retry after ${delayMs}ms, reason=$state")
    }

    /**
     * 执行一次自动回连尝试。
     *
     * 每次尝试都使用 Android passive `connectGatt(true)`。
     */
    private fun beginAttempt(uuid: String) {
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

        // 3. 已连接/已有 passive GATT 时不重复打开新 GATT。
        // passive GATT 的刷新由 watchdog 按 connectTimeout 统一关闭和重建。
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

        // 6. autoReconnect 全程使用 passive autoConnect，不切换到 connectGatt(false)。
        if (!config.autoReconnectUseNativePassive) {
            sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, native passive disabled by config")
            return
        }
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
            // CONNECTING 已经发给 Dart；autoReconnect 未取消前 UI 继续保持连接中。
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
     * Android `autoConnect=true` 可能长期 pending 且不回调；这里用 connectTimeout 作为
     * 一轮 passive session 的 deadline。到期仍未 connected 时关闭旧 GATT，1.5s 后重建，
     * 既避免无限躺在系统 pending 队列，也避免过高频率 register/unregister。
     */
    private fun startPassiveWatchdog(task: BleReconnectTask, config: BleConfig) {
        // 1. 同一 task 只保留一个 watchdog。
        task.timer?.cancel()
        val timer = Timer()
        task.timer = timer

        // 2. 每轮 passive autoConnect 最多等待 connectTimeout。
        val watchdogMs = config.connectTimeout.toLong().coerceAtLeast(1000L)
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

                    // 5. pending passive GATT 存在但 deadline 已到，关闭并在固定防抖后重建。
                    if (current.passiveGatt != null) {
                        try {
                            current.passiveGatt?.disconnect()
                            current.passiveGatt?.close()
                        } catch (error: Exception) {
                            sendLog(BleLoggerTag.e, "Auto reconnect: ${task.uuid}, close expired passive gatt error = ${error.message}")
                        }
                        current.passiveGatt = null
                        current.timer = null
                        sendLog(
                            BleLoggerTag.d,
                            "Auto reconnect: ${task.uuid}, passive deadline reached, rebuild after ${PASSIVE_RECONNECT_DEBOUNCE_MS}ms",
                        )
                        schedule(task.uuid, BleConnectState.TIMEOUT)
                        return@launch
                    }

                    current.timer = null

                    // 6. 只有 pending handle 已经丢失时才重建；不向 Dart/UI 推 TIMEOUT。
                    sendLog(BleLoggerTag.d, "Auto reconnect: ${task.uuid}, passive watchdog rebuild missing handle")
                    schedule(task.uuid, BleConnectState.TIMEOUT)
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

    private companion object {
        /** Even 插件内部的蓝牙开启状态值。 */
        private const val BLE_STATE_ON = 5

        /** passive GATT 到期后固定防抖，降低 Android register/unregister 过频风险。 */
        private const val PASSIVE_RECONNECT_DEBOUNCE_MS = 1500L

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
    }
}
