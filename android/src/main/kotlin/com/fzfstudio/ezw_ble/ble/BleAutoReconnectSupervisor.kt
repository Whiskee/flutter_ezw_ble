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
import java.util.ArrayDeque
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
    private val createConnectCallback: (String, BleConnectSource, Long) -> BleGattSessionCallback,
    /** 提升已经进入 Gate waiting queue 的同一 session，不抢占 active。 */
    private val promotePendingAdmission: (String) -> Unit,
    /** 持久化业务确认 connected 的回连目标。 */
    private val persistReconnectTarget: (BleDevice) -> Unit,
    /** 推进连接状态，由 manager 统一清理 GATT/队列/事件。 */
    private val handleConnectState: (String, String, BleConnectState) -> Unit,
    /** 统一日志出口。 */
    private val sendLog: (BleLoggerTag, String) -> Unit,
    /**
     * 查询 Supervisor 保存的 GATT 是否仍由 Manager/Gate 精确持有。
     *
     * 手动提升必须先做健康检查；假的 `passiveGatt != null` 不能被当成可复用 owner。
     */
    private val classifyPendingPassiveGattOwner:
        (String, BluetoothGatt) -> BlePendingOwnerHealth,
    /**
     * 精确撤销尚未收到物理 callback 的 admission。
     *
     * deadline 只能撤销仍由相同 GATT 持有的 pre-physical session；已经进入 Gate 的
     * 返回明确 disposition，调用方必须处理 stale、已 admission 和业务 connected，
     * 禁止再次通过布尔值静默退出。
     */
    private val invalidatePendingPassiveGatt:
        (String, BluetoothGatt) -> BlePendingOwnerDisposition,
    /**
     * 更高 Dart session 接管时精确撤销旧物理 owner。
     *
     * 与 pre-physical deadline 不同，这里允许撤销已经进入 Gate 的 exact admission；
     * manager 必须先失效旧 attempt、释放 GATT/Gate，再返回允许 supervisor 创建唯一新 owner。
     */
    private val invalidatePassiveGattForSessionRebind: (String, BluetoothGatt) -> Boolean,
    /** 创建长期 passive GATT 的平台边界；测试可注入 fake 验证 autoConnect pending 次序。 */
    private val passiveGattFactory: BlePassiveGattFactory = AndroidBlePassiveGattFactory,
    /** 扫描确认目标可见后的单次 `autoConnect=false` 直连平台边界。 */
    private val visibleDirectGattFactory: BlePassiveGattFactory = AndroidBleVisibleDirectGattFactory,
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
     * 目标可见不再只重建 passive owner，而是排队执行一次真实直连。
     *
     * 这里仅串行“发起物理直连”阶段；收到 `STATE_CONNECTED` 后仍交给既有 admission
     * Gate 串行 service/CCCD/鉴权。这样不会让扫描 burst 同时打开多条 HCI 建链。
     */
    private val visibleDirectConnectQueue = ArrayDeque<String>()
    private var activeVisibleDirectConnectUuid: String? = null

    /**
     * 将业务确认 connected 的设备加入 native 自动回连。
     *
     * 只有 Dart 调用 `deviceConnected` 后才应该 arm，避免 GATT ready 但业务认证失败的设备被恢复。
     */
    fun arm(
        device: BleDevice,
        source: BleConnectSource = BleConnectSource.AUTO_RECONNECT,
        sessionGeneration: Long = 0L,
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
                sessionGeneration = sessionGeneration,
            )
        } else {
            task.name = device.name
            // 2.1、没有 live GATT 时可以直接推进 task session；一旦 callback 已创建，
            // session 必须由 activate() 走 exact cancellation barrier 后再切换。
            if (sessionGeneration > task.sessionGeneration && task.passiveGatt == null) {
                task.sessionGeneration = sessionGeneration
            }
            // source 只属于当前 attempt：manual 提升后，lifecycle/重入 activate(auto)
            // 不能在物理 callback 前把它降级；但业务 connected 后的重新 arm 必须
            // 将下一次系统断线回连复位为 autoReconnect。
            task.source = BleReconnectSourcePolicy.onArm(
                current = task.source,
                incoming = source,
                businessConnected = device.connectState.isConnected,
            )
            // 2.2、普通 arm 只刷新持久 owner，不能越过 Bluetooth On 恢复屏障。
            // 蓝牙恢复后的旧 session 必须等 activate() 携带 Dart 最终合并 session
            // 才能解锁；否则 seed/arm 会提前复活旧 callback，再次制造代次竞态。
            // activate() 会重复进入 arm()。只有业务已确认 connected 时才算一次完整恢复，
            // disconnected 重入不得清空长离线退避或取消正在等待的 passive retry。
            if (device.connectState.isConnected) {
                task.attempt = 0
                task.consecutivePrePhysicalTimeouts = 0
                task.securityFailureCount = 0
                task.lastCountedSecurityAttemptGeneration = 0L
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
    fun activate(
        device: BleDevice,
        source: BleConnectSource,
        sessionGeneration: Long = 0L,
    ): Long {
        // 1、登记/刷新长期目标；这一步不创建第二条 GATT。
        arm(device, source, sessionGeneration)
        val task = reconnectTasks[reconnectKey(device.uuid)] ?: return 0L
        // 用户点击连接开启新的安全恢复 episode；该 attempt 首次安全失败直接交给 boundFail。
        if (source == BleConnectSource.MANUAL_RECONNECT) {
            task.securityFailureCount = 0
            task.lastCountedSecurityAttemptGeneration = 0L
        }
        // 1.1、只有显式 activation 才能消费 Bluetooth On 恢复屏障。
        // 此时 sessionAction 会在任何新 GATT 创建前完成 session 安装或 exact rebind。
        task.pausedByBluetoothOff = false
        task.awaitingRecoveryActivation = false

        // 2、session 未变化时复用当前 owner；更高 session 必须重建 callback 归属，
        // 不能只改 task 字段后让旧 GATT 冒充新会话。
        val sessionAction = BleReconnectSessionUpdatePolicy.resolve(
            currentSessionGeneration = task.sessionGeneration,
            incomingSessionGeneration = sessionGeneration,
            hasPhysicalOwner = task.passiveGatt != null,
        )
        if (sessionAction == BleReconnectSessionUpdateAction.REBUILD_PHYSICAL_OWNER) {
            val exactGatt = task.passiveGatt
            val previousSessionGeneration = task.sessionGeneration
            if (exactGatt != null && invalidatePassiveGattForSessionRebind(device.uuid, exactGatt)) {
                val rebound = synchronized(this) {
                    val current = reconnectTasks[reconnectKey(device.uuid)] ?: return@synchronized false
                    if (current.passiveGatt !== exactGatt) {
                        return@synchronized false
                    }
                    // 2.1、manager 已完成旧 admission/GATT 的 exact teardown；这里再清
                    // supervisor 引用并安装新 session，随后创建的 callback 才能携带新值。
                    current.pendingPhysicalDeadline?.cancel()
                    current.pendingPhysicalDeadline = null
                    invalidateRetrySchedule(current)
                    current.passiveGatt = null
                    current.passiveStartedAtMs = 0L
                    current.pendingVisibleDirectConnect = false
                    current.visibleDirectConnectRequested = false
                    current.sessionGeneration = sessionGeneration
                    true
                }
                if (rebound) {
                    releaseVisibleDirectConnectSlot(device.uuid)
                    sendLog(
                        BleLoggerTag.d,
                        "Auto reconnect: ${device.uuid}, session owner rebuilt " +
                            "old=$previousSessionGeneration, incoming=$sessionGeneration",
                    )
                    beginInitialAttempt(device.uuid)
                }
            }
            val actualSession = reconnectTasks[reconnectKey(device.uuid)]?.sessionGeneration ?: 0L
            if (actualSession != sessionGeneration) {
                sendLog(
                    BleLoggerTag.e,
                    "Auto reconnect: ${device.uuid}, session rebind not installed " +
                        "requested=$sessionGeneration actual=$actualSession",
                )
            }
            return actualSession
        }

        // 3、没有 live GATT 的 task 可以安全安装更高 session；旧/同 session 不倒退。
        if (sessionAction == BleReconnectSessionUpdateAction.UPDATE_TASK) {
            task.sessionGeneration = sessionGeneration
        }

        // 4、手动接管前校验 Supervisor/Manager/Gate 是否仍指向同一个 owner。
        // 4.1、若旧 deadline/Gate 清理只完成了一半，先精确修复 orphan，再创建唯一
        // replacement；不能继续把 `passiveGatt != null` 当作健康 owner。
        if (source == BleConnectSource.MANUAL_RECONNECT && task.passiveGatt != null) {
            val exactGatt = task.passiveGatt ?: return task.sessionGeneration
            if (
                classifyPendingPassiveGattOwner(device.uuid, exactGatt) ==
                BlePendingOwnerHealth.STALE
            ) {
                val disposition = repairStalePendingOwner(device.uuid, exactGatt)
                if (
                    disposition == BlePendingOwnerDisposition.INVALIDATED ||
                    disposition == BlePendingOwnerDisposition.REPAIRED_STALE_OWNER
                ) {
                    clearRecycledPendingOwner(device.uuid, exactGatt)
                    beginInitialAttempt(device.uuid)
                } else if (disposition == BlePendingOwnerDisposition.STALE_OWNER_DROPPED) {
                    // Manager 已有另一条健康 owner；只清 Supervisor 旧引用，不得重复建链。
                    clearRecycledPendingOwner(device.uuid, exactGatt)
                }
                return reconnectTasks[reconnectKey(device.uuid)]?.sessionGeneration ?: 0L
            }
        }

        // 5、已有健康 passive owner 时只提升 pending admission，复用当前 GATT。
        if (task.passiveGatt != null || task.timer != null) {
            if (source == BleConnectSource.MANUAL_RECONNECT) {
                promotePendingAdmission(device.uuid)
            }
            return task.sessionGeneration
        }
        // 6、首次 activation 同步执行 connectGatt(true)，确保返回前系统已经持有 pending owner。
        // 首轮不能通过 Timer(0) 异步跳出 MethodChannel：调用返回前必须已经同步执行
        // connectGatt(true)，这样上层随后启动扫描时所有有效目标都已进入系统 pending。
        beginInitialAttempt(device.uuid)
        return reconnectTasks[reconnectKey(device.uuid)]?.sessionGeneration ?: 0L
    }

    /**
     * 手动连接复用已有 autoReconnect pending GATT，并提升 Gate waiting source。
     * 返回 true 表示 manager 不得继续打开 foreground duplicate GATT。
     */
    fun promotePendingAttempt(uuid: String): Boolean {
        // 1、只有同一 uuid 已有 pending attempt 才允许提升；没有 owner 交给新 activation。
        val task = reconnectTasks[reconnectKey(uuid)] ?: return false
        task.securityFailureCount = 0
        task.lastCountedSecurityAttemptGeneration = 0L
        if (task.passiveGatt == null && task.timer == null) {
            return false
        }
        // 2、前台兼容入口也必须执行 owner 健康检查，不能绕过 activate() 的 stale 修复。
        task.passiveGatt?.let { exactGatt ->
            if (
                classifyPendingPassiveGattOwner(uuid, exactGatt) ==
                BlePendingOwnerHealth.STALE
            ) {
                val disposition = repairStalePendingOwner(uuid, exactGatt)
                task.source = BleConnectSource.MANUAL_RECONNECT
                when (disposition) {
                    BlePendingOwnerDisposition.INVALIDATED,
                    BlePendingOwnerDisposition.REPAIRED_STALE_OWNER -> {
                        clearRecycledPendingOwner(uuid, exactGatt)
                        beginInitialAttempt(uuid)
                    }
                    BlePendingOwnerDisposition.STALE_OWNER_DROPPED -> {
                        clearRecycledPendingOwner(uuid, exactGatt)
                        promotePendingAdmission(uuid)
                    }
                    BlePendingOwnerDisposition.ALREADY_ADMITTED,
                    BlePendingOwnerDisposition.BUSINESS_CONNECTED ->
                        promotePendingAdmission(uuid)
                }
                return true
            }
        }
        // 3、切换当前 attempt source，并把 admission 节点移入 manual 优先队列。
        task.source = BleConnectSource.MANUAL_RECONNECT
        promotePendingAdmission(uuid)
        return true
    }

    /**
     * OTA reboot 前只剥离当前物理 GATT，保留长期 reconnect task 与持久化 owner。
     *
     * 业务 connected 后 [onPassivePhysicalConnected] 会刻意保留 exact GATT，并取消
     * pre-physical deadline。固件 reboot teardown 随后会由 manager 关闭该 GATT；如果
     * task 仍保留旧引用，afterUpgrade/manual activation 会误判为仍有 pending attempt，
     * 永远只提升旧 owner 而不会创建新的 connectGatt。
     *
     * 本方法不关闭仍由 BleDevice 持有的 GATT，避免与 manager 的统一 teardown 重复抢占；
     * 仅当 supervisor 引用已经和 BleDevice 脱钩时，才回收这个孤立句柄。
     */
    fun detachPhysicalGattForOtaReboot(uuid: String): Boolean {
        val detachedGatt = synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return false
            invalidateRetrySchedule(task)
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null
            task.pendingVisibleDirectConnect = false
            task.visibleDirectConnectRequested = false
            val gatt = task.passiveGatt
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
            gatt
        }

        val deviceOwnsGatt = connectedDevices.firstOrNull {
            it.uuid.equals(uuid, ignoreCase = true)
        }?.myGatt === detachedGatt
        if (detachedGatt != null && !deviceOwnsGatt) {
            runCatching { detachedGatt.disconnect() }
            runCatching { detachedGatt.close() }
        }
        releaseVisibleDirectConnectSlot(uuid)
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: $uuid, OTA reboot detached physical GATT, owner preserved, hadGatt=${detachedGatt != null}",
        )
        return true
    }

    /**
     * 真实 `STATE_CONNECTED` callback 到达时，取消相同 GATT 的 pending deadline。
     *
     * 保留 exact GATT 作为业务 connected 后系统断连的 owner；只清 deadline，
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
        val mode = if (task.pendingVisibleDirectConnect) "visible direct" else "passive"
        task.pendingVisibleDirectConnect = false
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: $uuid, $mode physical callback after ${waitedMs}ms, attempt=${task.attempt}",
        )
        releaseVisibleDirectConnectSlot(uuid)
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
        task.pendingVisibleDirectConnect = false
        task.visibleDirectConnectRequested = false
        try {
            task.passiveGatt?.disconnect()
            task.passiveGatt?.close()
        } catch (error: Exception) {
            sendLog(BleLoggerTag.e, "Auto reconnect: $uuid, close passive gatt error = ${error.message}")
        }
        task.passiveGatt = null
        task.passiveStartedAtMs = 0L
        releaseVisibleDirectConnectSlot(uuid)
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
     * Android 蓝牙关闭会让当前 GATT binder 失效；这里只暂停并关闭失效句柄，
     * 等待 powered-on 后按统一直连契约重建长期 passive owner。
     */
    fun pauseForBluetoothOff() {
        // 1、先清空可见直连槽位，避免蓝牙关闭后残留物理 owner。
        // transport reset 不能遗留一个永远占用的直连槽位；所有 task 都会在恢复后回到 passive。
        synchronized(this) {
            visibleDirectConnectQueue.clear()
            activeVisibleDirectConnectUuid = null
        }
        // 2、清掉延迟 timer，并标记为蓝牙关闭导致的暂停。
        reconnectTasks.values.forEach { task ->
            task.pausedByBluetoothOff = true
            task.awaitingRecoveryActivation = false
            task.source = BleReconnectSourcePolicy.afterTransportReset()
            invalidateRetrySchedule(task)
            task.consecutivePrePhysicalTimeouts = 0
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null
            task.pendingVisibleDirectConnect = false
            task.visibleDirectConnectRequested = false

            // 2.1、passive GATT 不可复用，必须 close 后等待下一轮重新 connectGatt。
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
     * 蓝牙 powered-on 后恢复此前暂停的长期回连。
     *
     * 这里只解除 transport 层冻结，不直接用旧 session 创建 GATT。Dart 收到 BLE available
     * 后会为眼镜与戒指建立一个最终 recovery session，并通过 `activate()` 原子解除屏障。
     */
    fun resumeAfterBluetoothOn() {
        // 1、只标记因蓝牙关闭暂停的任务等待 Dart activation。
        // 1.1、保持 paused=true 可以阻止 BT-off 迟到终态或旧 timer 抢先 schedule。
        reconnectTasks.values
            .filter { it.pausedByBluetoothOff }
            .forEach { task ->
                task.awaitingRecoveryActivation = true
                task.source = BleReconnectSourcePolicy.afterTransportReset()
                sendLog(
                    BleLoggerTag.d,
                    "Auto reconnect: ${task.uuid}, bluetooth on, " +
                        "awaiting Dart recovery activation for final session",
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
     * 消费一次 exact 安全建立失败。
     *
     * 自动来源按 endpoint episode 计数，手动/前台来源不进入五次循环；同一 native attempt
     * 的多个系统证据只返回一次有效动作。
     */
    @Synchronized
    fun recordSecurityFailure(
        uuid: String,
        source: BleConnectSource,
        attemptGeneration: Long,
    ): BleAndroidSecurityRecoveryAction {
        val task = reconnectTasks[reconnectKey(uuid)]
        if (source != BleConnectSource.AUTO_RECONNECT || task == null) {
            return BleAndroidSecurityRecoveryAction.MANUAL_FAILURE
        }
        val (action, nextCount) = BleAndroidSecurityRecoveryPolicy.record(
            source = source,
            attemptGeneration = attemptGeneration,
            currentCount = task.securityFailureCount,
            lastCountedAttemptGeneration = task.lastCountedSecurityAttemptGeneration,
        )
        if (action != BleAndroidSecurityRecoveryAction.DUPLICATE_IGNORED) {
            task.securityFailureCount = nextCount
            task.lastCountedSecurityAttemptGeneration = attemptGeneration
        }
        sendLog(
            if (action == BleAndroidSecurityRecoveryAction.EXHAUSTED) BleLoggerTag.e else BleLoggerTag.d,
            "Security recovery: $uuid, source=${source.flutterValue}, " +
                "attemptGeneration=$attemptGeneration, count=${task.securityFailureCount}, action=$action",
        )
        return action
    }

    /** Gate 成功证明共享密钥可用，结束当前 endpoint 的恢复 episode。 */
    @Synchronized
    fun resetSecurityRecovery(uuid: String) {
        reconnectTasks[reconnectKey(uuid)]?.let { task ->
            task.securityFailureCount = 0
            task.lastCountedSecurityAttemptGeneration = 0L
        }
    }

    /**
     * 系统设置移除配对时回收仍在等待物理 callback 的 exact GATT。
     *
     * 该动作不是安全失败：它只替代原 20 秒 physical deadline，并在 250ms 防抖后用新
     * callback/generation 建链。已进入 admission 或业务 connected 的 owner 由 manager 拒绝。
     */
    fun rebuildAfterPrePhysicalBondRemoval(uuid: String): Boolean {
        val expectedGatt = synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return false
            if (task.passiveGatt == null || task.pendingPhysicalDeadline == null) {
                return false
            }
            task.passiveGatt
        } ?: return false

        val disposition = invalidatePendingPassiveGatt(uuid, expectedGatt)
        if (disposition != BlePendingOwnerDisposition.INVALIDATED &&
            disposition != BlePendingOwnerDisposition.REPAIRED_STALE_OWNER
        ) {
            if (disposition == BlePendingOwnerDisposition.STALE_OWNER_DROPPED) {
                clearRecycledPendingOwner(uuid, expectedGatt)
            }
            return false
        }

        val scheduleGeneration = synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return false
            if (task.passiveGatt !== expectedGatt) {
                return false
            }
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null
            invalidateRetrySchedule(task)
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
            task.pendingVisibleDirectConnect = false
            task.visibleDirectConnectRequested = false
            val next = nextScheduleGeneration(task.retryScheduleGeneration)
            task.retryScheduleGeneration = next
            task.timer = attemptDispatcher.dispatch(
                task.uuid,
                BlePassiveReconnectDelayPolicy.VISIBLE_WAKE_DEBOUNCE_MS,
                next,
            )
            next
        }
        releaseVisibleDirectConnectSlot(uuid)
        sendLog(
            BleLoggerTag.d,
            "Security recovery: $uuid, BONDED->NONE recycled pre-physical GATT, " +
                "rebuild after ${BlePassiveReconnectDelayPolicy.VISIBLE_WAKE_DEBOUNCE_MS}ms, " +
                "scheduleGeneration=$scheduleGeneration",
        )
        return true
    }

    /**
     * 冻结指定 endpoint 的长期回连 owner 元数据。
     *
     * 1. 对账层只能依赖这份不可变快照判断 owner 是否仍存在。
     * 2. 不暴露 task/GATT，避免 App foreground 查询意外改变重连计时或物理 owner。
     */
    @Synchronized
    fun ownerSnapshot(uuid: String): BleReconnectOwnerSnapshot? {
        val task = reconnectTasks[reconnectKey(uuid)] ?: return null
        return BleReconnectOwnerSnapshot(
            belongConfig = task.belongConfig,
            uuid = task.uuid,
            name = task.name,
            sn = task.sn,
            source = task.source,
            sessionGeneration = task.sessionGeneration,
        )
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
        forceVisibleDirectConnect: Boolean = false,
    ) {
        // 1. 非回连状态直接忽略。
        if (!shouldScheduleReconnect(state)) {
            return
        }

        // 2. 只有已经 arm 的设备才允许自动回连。
        val task = reconnectTasks[reconnectKey(uuid)] ?: return
        val config = bleConfigs().firstOrNull { it.name == task.belongConfig } ?: return

        // 2.1、蓝牙刚恢复时必须等 Dart 用一个最终 session 提交全部端点；旧终态不得
        // 在 EventChannel available 处理前抢跑旧 GATT。
        if (task.awaitingRecoveryActivation) {
            sendLog(
                BleLoggerTag.d,
                "Auto reconnect: $uuid, schedule deferred while awaiting recovery activation",
            )
            return
        }

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
        // 直连收到失败终态时必须交还物理槽位；否则后续已可见 endpoint 会永久停在队列。
        task.pendingVisibleDirectConnect = false
        task.visibleDirectConnectRequested = forceVisibleDirectConnect
        releaseVisibleDirectConnectSlot(uuid)

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
        task.pendingPassiveRetry = delayMs > 0L && visibilityWakeEligible && !forceVisibleDirectConnect
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
     * 常态使用 Android passive `connectGatt(true)`；只有辅助扫描确认目标可见时才消费
     * 一次直连请求，并且必须先取得全局物理连接槽位。
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

        // 5. 可见目标必须走一次真实直连，而不是把 `connectGatt(true)` 重新注册给系统。
        //    未取得槽位时保留请求并等待前一个目标收到物理回调或 deadline，避免 HCI 并发。
        val useVisibleDirectConnect = task.visibleDirectConnectRequested
        if (useVisibleDirectConnect && !acquireVisibleDirectConnectSlot(task.uuid)) {
            return
        }

        // 6. 递增 attempt，并清理上一轮 GATT。attempt 只参与日志诊断，
        //    不再决定是否停止回连，避免设备离开较久后 native 主动放弃。
        task.attempt = nextAttemptCount(task.attempt)
        task.passiveGatt?.close()
        task.passiveGatt = null
        task.passiveStartedAtMs = 0L
        task.visibleDirectConnectRequested = false

        if (useVisibleDirectConnect) {
            beginVisibleDirectReconnect(task, config)
        } else {
            beginPassiveReconnect(task, config)
        }
    }

    /**
     * 启动 Android native passive autoConnect。
     *
     * passive 只恢复物理链路；连接成功后仍会进入同一套 service/char/notify 初始化。
     */
    private fun beginPassiveReconnect(task: BleReconnectTask, config: BleConfig) {
        beginReconnectGatt(
            task = task,
            config = config,
            gattFactory = passiveGattFactory,
            isVisibleDirectConnect = false,
        )
    }

    /** 扫描已确认目标广播正常时，执行一次 `autoConnect=false` 的真实物理建链。 */
    private fun beginVisibleDirectReconnect(task: BleReconnectTask, config: BleConfig) {
        beginReconnectGatt(
            task = task,
            config = config,
            gattFactory = visibleDirectGattFactory,
            isVisibleDirectConnect = true,
        )
    }

    /**
     * 两种自动回连 GATT 的共享启动逻辑。
     *
     * 直连仍保留 autoReconnect source，因而物理 callback 前不会展示 UI connecting；它仅
     * 改变 Android 是否立即发起建链，不创建 foreground 第二 owner。
     */
    private fun beginReconnectGatt(
        task: BleReconnectTask,
        config: BleConfig,
        gattFactory: BlePassiveGattFactory,
        isVisibleDirectConnect: Boolean,
    ) {
        val mode = if (isVisibleDirectConnect) "visible direct" else "passive"
        // 1. 通过已知 address 构造 BluetoothDevice；真正连接由 Android 协议栈等待设备出现。
        val remoteDevice = bluetoothAdapter().getRemoteDevice(task.uuid)
        val cachedDevice = connectedDevices.firstOrNull { it.uuid.equals(task.uuid, ignoreCase = true) }
        val resolvedName = resolveBleDeviceName(remoteDevice.name, task.name, cachedDevice?.name)

        // 2. 没有稳定 name 时不能进入 GATT，否则状态/日志无法匹配业务设备。
        if (resolvedName == null) {
            sendLog(BleLoggerTag.e, "Auto reconnect: ${task.uuid}, $mode skipped, device name missing")
            if (isVisibleDirectConnect) {
                releaseVisibleDirectConnectSlot(task.uuid)
            }
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
        val callback = createConnectCallback(task.uuid, task.source, task.sessionGeneration)

        // 5. 常态由 autoConnect=true 保留长期意图；可见目标只在单槽位中直连一次。
        val gatt = gattFactory.connect(
            remoteDevice,
            context(),
            callback,
            config.androidHighReliabilityMode,
        )

        // 6. 系统未创建 GATT session 时，按 timeout 进入下一轮调度。
        if (gatt == null) {
            sendLog(BleLoggerTag.e, "Auto reconnect: ${task.uuid}, $mode connectGatt returned null")
            if (isVisibleDirectConnect) {
                releaseVisibleDirectConnectSlot(task.uuid)
            }
            schedule(task.uuid, BleConnectState.TIMEOUT)
            return
        }

        // 7. 保存 exact GATT 并只监控“尚未收到 STATE_CONNECTED”的阶段。deadline
        //    到期不会上报 Dart timeout 或停掉长期 intent，而是 exact close + 自适应退避重建。
        bleDevice.update(gatt)
        task.passiveGatt = gatt
        task.pendingVisibleDirectConnect = isVisibleDirectConnect
        task.passiveStartedAtMs = SystemClock.elapsedRealtime()
        startPendingPhysicalDeadline(task, config, gatt)
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: ${task.uuid}, $mode attempt ${task.attempt} started, physicalDeadline=${pendingPhysicalDeadlineMs(config)}ms",
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
        // 此处返回明确 disposition，deadline 只失效自身，绝不触碰 queued session。manager 调用必须
        // 在 supervisor monitor 外执行，避免 physical callback 的 manager→supervisor 反向锁序。
        val disposition = invalidatePendingPassiveGatt(uuid, expectedGatt)
        if (
            disposition == BlePendingOwnerDisposition.ALREADY_ADMITTED ||
            disposition == BlePendingOwnerDisposition.BUSINESS_CONNECTED
        ) {
            synchronized(this) {
                val task = reconnectTasks[reconnectKey(uuid)] ?: return
                if (task.passiveGatt === expectedGatt) {
                    task.pendingPhysicalDeadline?.cancel()
                    task.pendingPhysicalDeadline = null
                }
            }
            sendLog(
                BleLoggerTag.d,
                "Auto reconnect: $uuid, physical deadline ignored, owner=$disposition",
            )
            return
        }
        if (disposition == BlePendingOwnerDisposition.STALE_OWNER_DROPPED) {
            clearRecycledPendingOwner(uuid, expectedGatt)
            sendLog(
                BleLoggerTag.d,
                "Auto reconnect: $uuid, stale deadline owner dropped; manager owner preserved",
            )
            return
        }

        val (timeoutCount, retryDelayMs, wasVisibleDirectConnect) = synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return
            if (task.passiveGatt !== expectedGatt || task.pendingPhysicalDeadline == null) {
                return
            }
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
            val wasVisibleDirectConnect = task.pendingVisibleDirectConnect
            task.pendingVisibleDirectConnect = false
            task.consecutivePrePhysicalTimeouts = nextAttemptCount(task.consecutivePrePhysicalTimeouts)
            val timeoutCount = task.consecutivePrePhysicalTimeouts
            Triple(
                timeoutCount,
                BlePassiveReconnectDelayPolicy.delayAfterConsecutivePrePhysicalTimeouts(timeoutCount),
                wasVisibleDirectConnect,
            )
        }
        if (wasVisibleDirectConnect) {
            releaseVisibleDirectConnectSlot(uuid)
        }
        val mode = if (wasVisibleDirectConnect) "visible direct" else "passive"
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: $uuid, $mode deadline ${deadlineMs}ms reached, consecutive=$timeoutCount, rebuild after ${retryDelayMs}ms",
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
     * 扫描重新看到目标时，接管 exact pre-physical owner 或它的 pending retry。
     *
     * 已物理连接/Gate queued、用户取消、蓝牙关闭均返回 false。接管后会在单槽位中执行
     * 一次 `connectGatt(false)`，并继续保持 autoReconnect source 与长期 passive owner。
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

            // 已经在执行可见性直连时，扫描 burst 不得把它再次 close/reopen；否则会把
            // 真正的 HCI 建链反复打断。返回 true 表示该次可见性已被当前 attempt 消费。
            if (task.pendingVisibleDirectConnect || task.visibleDirectConnectRequested) {
                return true
            }

            val exactGatt = task.passiveGatt
            val hasPrePhysicalGatt = exactGatt != null && task.pendingPhysicalDeadline != null
            val hasPendingRetry = exactGatt == null && task.timer != null && task.pendingPassiveRetry
            if (!hasPrePhysicalGatt && !hasPendingRetry) {
                return false
            }

            if (hasPendingRetry) {
                prepareTargetVisibleDirectConnect(task, name)
                true
            } else {
                expectedGatt = exactGatt
                false
            }
        }
        if (pendingRetryWake) {
            // 调度放在 supervisor monitor 外；用户 cancel 与本次 wake 竞争时由 task
            // identity 自然 fail closed，且不会把锁带入 Timer/GATT 创建路径。
            scheduleTargetVisibleDirectConnect(uuid)
            return true
        }

        val exactGatt = expectedGatt ?: return false
        // manager 调用期间不持有 supervisor monitor，避免与 physical callback 的
        // manager→supervisor 顺序形成锁反转；manager 仍会拒绝已进入 Gate 的 exact GATT。
        val disposition = invalidatePendingPassiveGatt(uuid, exactGatt)
        if (
            disposition == BlePendingOwnerDisposition.ALREADY_ADMITTED ||
            disposition == BlePendingOwnerDisposition.BUSINESS_CONNECTED
        ) {
            synchronized(this) {
                val task = reconnectTasks[reconnectKey(uuid)] ?: return false
                if (task.passiveGatt === exactGatt) {
                    task.pendingPhysicalDeadline?.cancel()
                    task.pendingPhysicalDeadline = null
                }
            }
            sendLog(
                BleLoggerTag.d,
                "Auto reconnect: $uuid, visibility already consumed by owner=$disposition",
            )
            return true
        }
        if (disposition == BlePendingOwnerDisposition.STALE_OWNER_DROPPED) {
            clearRecycledPendingOwner(uuid, exactGatt)
            sendLog(
                BleLoggerTag.d,
                "Auto reconnect: $uuid, stale visibility owner dropped; manager owner preserved",
            )
            return true
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
            prepareTargetVisibleDirectConnect(task, name)
            true
        }
        if (!clearedExactGatt) {
            return false
        }
        // 与 deadline 路径一致，schedule 不持 supervisor monitor，保持单向锁序。
        scheduleTargetVisibleDirectConnect(uuid)
        return true
    }

    /**
     * 手动提升发现 stale owner 时复用 Manager 的 exact 修复入口。
     *
     * 该方法只在健康分类为 STALE 后调用；健康 pre-physical owner 仍由普通 promotion
     * 复用，避免手动点击制造多余 GATT。
     */
    private fun repairStalePendingOwner(
        uuid: String,
        exactGatt: BluetoothGatt,
    ): BlePendingOwnerDisposition = invalidatePendingPassiveGatt(uuid, exactGatt)

    /** Manager 已回收 exact owner 后，清除 Supervisor 对旧 GATT/deadline/timer 的全部引用。 */
    private fun clearRecycledPendingOwner(uuid: String, exactGatt: BluetoothGatt) {
        synchronized(this) {
            val task = reconnectTasks[reconnectKey(uuid)] ?: return
            if (task.passiveGatt !== exactGatt) {
                return
            }
            task.pendingPhysicalDeadline?.cancel()
            task.pendingPhysicalDeadline = null
            invalidateRetrySchedule(task)
            task.passiveGatt = null
            task.passiveStartedAtMs = 0L
            task.pendingVisibleDirectConnect = false
            task.visibleDirectConnectRequested = false
        }
        releaseVisibleDirectConnectSlot(uuid)
    }

    /** 在 supervisor 锁内重置可见目标的长离线计数，并标记一次真实直连。 */
    private fun prepareTargetVisibleDirectConnect(task: BleReconnectTask, name: String) {
        invalidateRetrySchedule(task)
        if (name.isNotBlank()) {
            task.name = name
        }
        task.consecutivePrePhysicalTimeouts = 0
        task.visibleDirectConnectRequested = true
    }

    /**
     * 可见性直连使用 250ms 防抖，但不复用 schedule(TIMEOUT)：后者会关闭这次 direct
     * 标记并退回 passive。真实连接的来源仍是 autoReconnect，不触发 Dart/UI connecting。
     */
    private fun scheduleTargetVisibleDirectConnect(uuid: String) {
        val task = synchronized(this) { reconnectTasks[reconnectKey(uuid)] } ?: return
        val scheduleGeneration = synchronized(this) {
            val current = reconnectTasks[reconnectKey(uuid)] ?: return
            val next = nextScheduleGeneration(current.retryScheduleGeneration)
            current.retryScheduleGeneration = next
            current.timer = attemptDispatcher.dispatch(
                current.uuid,
                BlePassiveReconnectDelayPolicy.VISIBLE_WAKE_DEBOUNCE_MS,
                next,
            )
            next
        }
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: ${task.uuid}, target visible, schedule direct reconnect after ${BlePassiveReconnectDelayPolicy.VISIBLE_WAKE_DEBOUNCE_MS}ms, generation=$scheduleGeneration",
        )
    }

    /**
     * 取得全局一次性直连槽位。相同 UUID 的重入视为已取得，其他 endpoint 只入队，不会
     * 同时调用 `connectGatt(false)`；原有 admission Gate 继续负责物理 callback 后的流程。
     */
    private fun acquireVisibleDirectConnectSlot(uuid: String): Boolean = synchronized(this) {
        val key = reconnectKey(uuid)
        when {
            activeVisibleDirectConnectUuid == key -> true
            activeVisibleDirectConnectUuid == null -> {
                activeVisibleDirectConnectUuid = key
                true
            }
            else -> {
                if (!visibleDirectConnectQueue.contains(key)) {
                    visibleDirectConnectQueue.addLast(key)
                }
                sendLog(BleLoggerTag.d, "Auto reconnect: $uuid, visible direct reconnect queued behind $activeVisibleDirectConnectUuid")
                false
            }
        }
    }

    /**
     * 当前直连拿到物理 callback、deadline 或终态后释放槽位，并异步启动下一条仍有效的请求。
     * `beginAttempt` 会再次校验 task、蓝牙状态和直连标记，所以 cancel/reset 的迟到排队项
     * 会自然 fail closed。
     */
    private fun releaseVisibleDirectConnectSlot(uuid: String) {
        val nextUuid = synchronized(this) {
            val key = reconnectKey(uuid)
            if (activeVisibleDirectConnectUuid != key) {
                visibleDirectConnectQueue.remove(key)
                return@synchronized null
            }
            activeVisibleDirectConnectUuid = null
            while (visibleDirectConnectQueue.isNotEmpty()) {
                val queuedKey = visibleDirectConnectQueue.removeFirst()
                val queuedTask = reconnectTasks[queuedKey] ?: continue
                if (!queuedTask.visibleDirectConnectRequested || queuedTask.passiveGatt != null) {
                    continue
                }
                activeVisibleDirectConnectUuid = queuedKey
                return@synchronized queuedTask.uuid
            }
            null
        }
        nextUuid?.let { queuedUuid ->
            mainScope().launch { beginAttempt(queuedUuid, expectedScheduleGeneration = null) }
        }
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
