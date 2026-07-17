package com.fzfstudio.ezw_ble.ble

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Context.BLUETOOTH_SERVICE
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.fzfstudio.ezw_ble.ble.extension.resolveBleDeviceName
import com.fzfstudio.ezw_ble.ble.extension.toBleDevice
import com.fzfstudio.ezw_ble.ble.models.BleCmd
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePendingScanConnect
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import com.fzfstudio.ezw_ble.ble.services.BleStateListener
import com.fzfstudio.ezw_ble.ble.services.BleStateListener.BluetoothStateCallback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference
import java.util.Collections
import java.util.Timer
import java.util.TimerTask
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject

class BleManager private constructor() {

    companion object {
        val instance: BleManager = BleManager()
        private const val logcatTag = "flutter_ezw_ble"
        /** 这些 callback 只属于连接 readiness pipeline，业务 connected 后的迟到回调也必须拒绝。 */
        private val connectionPipelineStages = setOf(
            "connection connected",
            "services discovered",
            "descriptor write",
            "descriptor enqueue failure",
            "request mtu",
            "mtu changed",
            "connect finish",
        )
        //  CCCD特征符号UUID
        val cccdDescriptor: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    /// =========== Constants
    //  - 主线程工局
    private lateinit var mainScope: CoroutineScope
    //  - 搜索配置
    private val scanSettings by lazy {
        ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
    }
    //  - 缓存已连接的设备
    private val connectedDevices: MutableList<BleDevice> = Collections.synchronizedList(mutableListOf())
    //  - 搜素结果临时缓存(DeviceInfo, 蓝牙对象)
    private val scanResultTemp: MutableList<BleDevice> = Collections.synchronizedList(mutableListOf())
    //  - 是否正在升级中
    private val upgradeDevices: MutableList<String> = Collections.synchronizedList(mutableListOf())
    //  - 指令发送队列。按 uuid 隔离，避免左右腿并发写回调把下一条指令写到错误的 GATT。
    private val sendCmdQueues: MutableMap<String, ConcurrentLinkedQueue<BleCmd>> =
        Collections.synchronizedMap(mutableMapOf())
    //  - 正在执行断连的设备
    private val disconnectingDevices: MutableList<Pair<String, BleConnectState>> = Collections.synchronizedList(mutableListOf())
    //  - 预连接设备集合（使用uuid作为key）
    private val preConnectedDevices: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    //  - 全局 GATT pipeline Gate：物理链路可以并发 pending，但 service/CCCD/业务鉴权只能串行。
    private val connectionAdmissionGate = BleConnectionAdmissionGate()
    //  - 每个 endpoint 的 attempt generation；同 uuid 新尝试会使旧 callback fail-closed。
    private val connectionAttemptGenerations: MutableMap<String, Long> =
        Collections.synchronizedMap(mutableMapOf())
    //  - sessionId 与 GATT 对象身份一起隔离同 generation 内的迟到回调。
    private val connectionSessionSequence = AtomicLong(0L)
    private val currentAdmissions: MutableMap<String, BleConnectionAdmission> =
        Collections.synchronizedMap(mutableMapOf())
    private val admittedGattSessions: MutableMap<Long, GrantedGattSession> =
        Collections.synchronizedMap(mutableMapOf())
    //  - Gate 释放后仍保存业务 connected session 的 exact admission + GATT identity；
    //    系统稍后断连时据此区分 live session 与旧 callback。
    private val businessConnectedGattSessions: MutableMap<String, BusinessConnectedGattSession> =
        Collections.synchronizedMap(mutableMapOf())
    // OTA reboot 主动 close 后仍会收到一条旧 GATT 的 STATE_DISCONNECTED。它已经由
    // disconnectForOtaReboot 上报过同代终态，必须只消费一次，不能再 schedule retry。
    private val otaRebootDisconnectSuppressions: MutableSet<String> =
        Collections.synchronizedSet(mutableSetOf())

    /** Gate 排队期间保留真实 GATT；只有获得准入后才启动 timeout 和 service discovery。 */
    private data class GrantedGattSession(
        val admission: BleConnectionAdmission,
        val gatt: BluetoothGatt,
        val device: BleDevice,
        val afterUpgrade: Boolean,
    )

    /** 业务 connected 已释放 Gate，但物理 GATT 仍长期存活。 */
    private data class BusinessConnectedGattSession(
        val admission: BleConnectionAdmission,
        val gatt: BluetoothGatt,
    )

    /** 蓝牙关闭前冻结的终态事件 metadata；Gate 清理后不能再从 runtime 表读取它。 */
    private data class BluetoothOffTerminalSnapshot(
        val uuid: String,
        val name: String,
        val source: BleConnectSource,
        val generation: Long,
    )

    //  - 扫描命中后再连接的待处理请求（非 directConnect 且目标未出现在 scanResultTemp 时入队）
    private val pendingScanConnects: MutableList<BlePendingScanConnect> =
        Collections.synchronizedList(mutableListOf())
    //  - scan-refresh 是“先扫 10s 再重入 connect”的延迟任务；必须按 uuid 可取消，
    //    否则用户断开/移除后旧协程仍可能重新打开 GATT。
    private val scanRefreshJobs: MutableMap<String, Job> =
        Collections.synchronizedMap(mutableMapOf())
    //  - 每次 scan-refresh 都分配新 generation。即使 cancel 与 delay 恢复同时发生，
    //    旧 generation 也不能继续推进 connect。
    private val scanRefreshGenerations: MutableMap<String, Long> =
        Collections.synchronizedMap(mutableMapOf())
    //  - 单调递增即可，不需要持久化；仅用于区分同 uuid 的新旧延迟任务。
    private var scanRefreshGenerationCounter: Long = 0
    //  - 自动回连持久化仓库，只负责配置快照、回连目标和事件缓冲
    private val reconnectStore = BleReconnectStore()
    //  - 自动回连监督器，只负责 task/passive autoConnect/watchdog
    private val autoReconnectSupervisor by lazy {
        BleAutoReconnectSupervisor(
            connectedDevices = connectedDevices,
            bleConfigs = { bleConfigs },
            bluetoothAdapter = { bluetoothAdapter },
            context = { weakContext?.get() },
            mainScope = { mainScope },
            bleState = { bleState },
            isBluetoothEnabled = { isBluetoothEnabled() },
            isUpgradeDevice = { uuid -> upgradeDevices.contains(uuid) },
            createConnectCallback = { expectedUuid, source ->
                createConnectCallBack(expectedUuid, source = source)
            },
            promotePendingAdmission = { uuid -> promotePendingAttempt(uuid) },
            persistReconnectTarget = { device -> persistReconnectTarget(device) },
            handleConnectState = { uuid, name, state -> handleConnectState(uuid, name, state) },
            sendLog = { tag, message -> sendLog(tag, message) },
            invalidatePendingPassiveGatt = { uuid, gatt -> invalidatePendingPassiveGatt(uuid, gatt) },
        )
    }


    /// =========== Private Variables
    private var weakContext: WeakReference<Context>? = null
    //  - 蓝牙管理工具
    private lateinit var bluetoothManager: BluetoothManager
    //  - 系统蓝牙状态监听
    // release 后清空引用；再次 release 不能对已经解绑的 receiver 再执行 unregister。
    private var bleStateListener: BleStateListener? = null
    //  - 蓝牙搜索状态，是否正在搜索中
    private var isScanning = false
    //  - 搜索纯净模式
    private var scanPureMode: Boolean = false
    //  - 蓝牙搜索回调
    private var scanCallback: ScanCallback? = null
    //  - 当前蓝牙状态,默认无状态
    private var bleState: Int = 0
    //  - 当前蓝牙权限,默认无权限
    private var blePermission: Boolean = false
    //  - 当前蓝牙定位权限，默认无权限
    private var bleLocation: Boolean = false
    //  - 当前蓝牙基础配置，必须实现
    private var bleConfigs: List<BleConfig> = listOf()

    /// =========== Get
    //  - 蓝牙状态
    val currentBleState
        get() = if (!bleLocation) 6 else if (!blePermission) 3 else bleState
    //  - 蓝牙业务处理
    private val bluetoothAdapter: BluetoothAdapter
        get() = bluetoothManager.adapter

    /**
     * 初始化工具
     */
    fun init(context: Context) {
        if (this::bluetoothManager.isInitialized &&
            this::mainScope.isInitialized &&
            mainScope.isActive
        ) {
            weakContext = WeakReference(context.applicationContext)
            restorePersistedConfigsIfNeeded()
            checkBluetoothPermission()
            return
        }
        mainScope = MainScope()
        weakContext = WeakReference(context.applicationContext)
        //  初始化蓝牙工具
        bluetoothManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.getSystemService(BluetoothManager::class.java)
        } else {
            context.getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        }
        //  主动查询蓝牙工具状态
        bleState = if (bluetoothAdapter.isEnabled) 5 else 4
        //  注册监听：蓝牙状态
        bleStateListener = BleStateListener(context).also {
            it.register(createBleStateListener())
        }
        restorePersistedConfigsIfNeeded()
        checkBluetoothPermission()
        sendLog(BleLoggerTag.d, "Init: success")
    }

    /**
     * 检查是否有蓝牙权限
     */
    fun checkBluetoothPermission() {
        weakContext?.get()?.let {
            // 1、蓝牙权限
            // Android 12 (API 31) 及以上使用 BLUETOOTH_SCAN 和 BLUETOOTH_CONNECT 权限
            blePermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                it.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
                        it.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            }
            // 在 Android 12 之前使用 BLUETOOTH_ADMIN 权限
            else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                it.checkSelfPermission(Manifest.permission.BLUETOOTH_ADMIN) == PackageManager.PERMISSION_GRANTED
            }
            // 在较旧版本中，不检查权限，因为 BLUETOOTH_ADMIN 是从 API 23 开始引入的
            else {
                true
            }
            sendLog(BleLoggerTag.d, "Ble status listener: permission = $blePermission")
            //  2、位置信息权限
            bleLocation = if (Build.VERSION.SDK_INT in Build.VERSION_CODES.M..Build.VERSION_CODES.R) {
                it.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
                        it.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
            }
            // Android 12+ 使用 BLUETOOTH_SCAN/CONNECT；如果 manifest 声明 neverForLocation，
            // 插件不能再强制要求位置权限，否则合法的现代 BLE 配置会被误判为 noLocation。
            else {
                true
            }
            BleEC.BLE_STATE.event?.success(currentBleState)
            sendLog(BleLoggerTag.d, "Ble status listener: location = $bleLocation, status = $currentBleState")
        }
    }

    /// 查找已连接的设备
    fun findConnectedDevice(uuid: String?): BleDevice? = if (uuid.isNullOrEmpty())
        null
    else
        connectedDevices.firstOrNull { it.uuid.equals(uuid, ignoreCase = true) }

    private fun currentDeviceForGatt(gatt: BluetoothGatt, stage: String): BleDevice? {
        val address = gatt.device.address
        val device = findConnectedDevice(address)
        if (device == null) {
            sendLog(BleLoggerTag.e, "Connect call back: $address $stage ignored, not my connected device")
            runCatching { gatt.close() }
            return null
        }
        if (device.myGatt !== gatt) {
            sendLog(BleLoggerTag.d, "Connect call back: $address $stage ignored, stale gatt")
            runCatching { gatt.close() }
            return null
        }
        return device
    }

    private fun writeNextCommand(uuid: String) {
        val key = reconnectKey(uuid)
        val queue = sendCmdQueues[key] ?: return
        while (true) {
            val cmd = queue.peek() ?: run {
                sendCmdQueues.remove(key)
                return
            }
            val device = findConnectedDevice(cmd.uuid)
            val started = device?.writeCharacteristic(cmd.data, cmd.psType) == true
            if (started) {
                return
            }
            queue.poll()
            sendLog(BleLoggerTag.e, "Send cmd: ${cmd.uuid}, write start failed, drop queued command")
        }
    }

    /// =========== Method: Flutter Method

    /**
     * 开启（设置）蓝牙配置
     *
     * @param newConfigs 要设置的蓝牙配置
     */
    @Synchronized
    fun initConfigs(newConfigs: List<BleConfig>) {
        // 配置删除或 autoReconnect true->false 是授权撤销，必须先终止旧 runtime/persisted owner，
        // 再发布新配置；否则旧 passive callback 可能在配置切换窗口重新进入 Gate。
        val revokedConfigNames = BleReconnectConfigDiff.revokedConfigNames(bleConfigs, newConfigs)
        if (revokedConfigNames.isNotEmpty()) {
            revokeReconnectConfigs(revokedConfigNames)
        }
        bleConfigs = newConfigs
        persistConfigs(newConfigs)
    }

    /**
     * 原子撤销指定配置下的 passive/pending/admission/session 与持久 owner。
     * 同批 endpoint 先全部失效，再 teardown GATT，最后只启动仍获授权的下一 Gate owner。
     */
    private fun revokeReconnectConfigs(configNames: Set<String>) {
        val taskEndpoints = autoReconnectSupervisor.endpointsForConfigs(configNames)
        val persistedEndpoints = reconnectStore.removeTargetsForConfigs(weakContext?.get(), configNames)
        val revokedDevices = connectedDevices.filter { it.belongConfig.name in configNames }
        val pendingEndpoints = pendingScanConnects
            .filter { it.belongConfig in configNames }
            .map { it.uuid }
        val endpointIds = (taskEndpoints + persistedEndpoints + revokedDevices.map { it.uuid } + pendingEndpoints)
            .filter { it.isNotBlank() }
            .toSet()
        val endpointKeys = endpointIds.map(::reconnectKey).toSet()

        // 1. 先快照被撤销 session 的 GATT；map/Gate 失效后迟到 callback 只能 fail closed。
        val revokedAdmissionSessions = admittedGattSessions.values
            .filter { reconnectKey(it.admission.endpointId) in endpointKeys }
        val revokedBusinessSessions = businessConnectedGattSessions
            .filterKeys { it in endpointKeys }
            .values
        currentAdmissions.keys
            .filter { it in endpointKeys }
            .forEach { currentAdmissions.remove(it) }
        revokedAdmissionSessions.forEach { admittedGattSessions.remove(it.admission.sessionId) }
        endpointKeys.forEach { businessConnectedGattSessions.remove(it) }
        endpointIds.forEach { endpointId ->
            val key = reconnectKey(endpointId)
            connectionAttemptGenerations[key] = nextConnectionGeneration(
                connectionAttemptGenerations[key] ?: 0L,
            )
        }
        val next = connectionAdmissionGate.cancelEndpoints(endpointIds)

        // 2. 清除尚未物理连接的扫描/命令/鉴权上下文，避免延迟任务重新打开 GATT。
        pendingScanConnects.removeAll { it.belongConfig in configNames }
        endpointIds.forEach { endpointId ->
            cancelScanRefresh(endpointId)
            preConnectedDevices.remove(endpointId)
            sendCmdQueues.remove(reconnectKey(endpointId))
            upgradeDevices.remove(endpointId)
        }
        scanResultTemp.removeAll { it.belongConfig.name in configNames }

        // 3. supervisor 与 connectedDevices 都可能引用同一 passive GATT；close 是幂等的，
        //    但 BleDevice.releaseAndClear 仍必须执行以清掉对象内的 GATT/characteristic 缓存。
        autoReconnectSupervisor.cancelConfigs(configNames, reason = "initConfigs revoked")
        val deviceGattHandles = revokedDevices.mapNotNull { it.myGatt }
        revokedDevices.forEach { device ->
            device.releaseAndClear()
            device.connectState = BleConnectState.NONE
        }
        (revokedAdmissionSessions.map { it.gatt } + revokedBusinessSessions.map { it.gatt })
            .distinctBy { System.identityHashCode(it) }
            .filter { gatt -> deviceGattHandles.none { it === gatt } }
            .forEach { gatt ->
                runCatching { gatt.disconnect() }
                runCatching { gatt.close() }
            }

        // 4. 被撤销 active 完整 teardown 后，才允许未撤权 endpoint 开始 pipeline。
        next?.let { startGrantedGattPipeline(it) }
        sendLog(
            BleLoggerTag.d,
            "Auto reconnect: revoked configs=$configNames endpoints=${endpointIds.size}",
        )
    }

    /**
     * 从 Dart 绑定缓存补种 native 自动回连目标。
     *
     * 该入口只建立长期回连 owner：不发起前台连接、不清其它设备 task、不修改系统 bond。
     * 用于旧缓存/进程恢复时当前 native 进程尚未经历 `deviceConnected` 的场景。
     */
    internal fun armAutoReconnectTargets(targets: List<BleReconnectSeed>) {
        if (targets.isEmpty()) {
            return
        }
        restorePersistedConfigsIfNeeded()
        targets.forEach { target ->
            val config = bleConfigs.firstOrNull { it.name == target.belongConfig }
            if (config == null) {
                sendLog(
                    BleLoggerTag.e,
                    "Auto reconnect: ${target.uuid}, seed ignored, config not found: ${target.belongConfig}",
                )
                return@forEach
            }
            if (!config.autoReconnect || target.uuid.isBlank()) {
                return@forEach
            }
            val seedDevice = BleDevice(
                belongConfig = config,
                name = target.name,
                uuid = target.uuid,
                sn = target.sn,
                rssi = target.rssi,
                connectState = BleConnectState.NONE,
            )
            autoReconnectSupervisor.arm(seedDevice)
            sendLog(BleLoggerTag.d, "Auto reconnect: ${target.uuid}, seeded native reconnect target")
        }
    }

    /**
     * 从 Dart 缓存立即激活所有长期 autoReconnect 目标。
     *
     * 每个目标都会马上建立/复用 Android `autoConnect=true` pending GATT；调用本方法不发送
     * connecting，只有真实 STATE_CONNECTED callback 才会上报 source-tagged contactDevice。
     */
    internal fun activateAutoReconnectTargets(
        targets: List<BleReconnectSeed>,
        source: BleConnectSource,
    ): List<BleReconnectActivationResult> {
        if (targets.isEmpty()) {
            return emptyList()
        }
        restorePersistedConfigsIfNeeded()
        return targets.map { target ->
            val config = bleConfigs.firstOrNull { it.name == target.belongConfig }
            if (config == null || !config.autoReconnect || target.uuid.isBlank()) {
                sendLog(
                    BleLoggerTag.e,
                    "Auto reconnect: ${target.uuid}, activation ignored, invalid identity/config=${target.belongConfig}",
                )
                return@map BleReconnectActivationResult(
                    target = target,
                    state = BleReconnectActivationState.REJECTED,
                    reason = if (target.uuid.isBlank()) "emptyIdentity" else "invalidConfig",
                )
            }
            val seedDevice = BleDevice(
                belongConfig = config,
                name = target.name,
                uuid = target.uuid,
                sn = target.sn,
                rssi = target.rssi,
                connectState = BleConnectState.NONE,
            )
            autoReconnectSupervisor.activate(seedDevice, source)
            BleReconnectActivationResult(
                target = target,
                state = BleReconnectActivationState.RESOLVED,
                reason = "",
            )
        }
    }

    /** 将辅助扫描的目标可见信号交给 exact native autoReconnect owner。 */
    internal fun notifyAutoReconnectTargetVisible(uuid: String, name: String): Boolean =
        autoReconnectSupervisor.notifyTargetVisible(uuid, name)

    /**
     *  开启扫描
     */
    fun startScan(pureModel: Boolean = false) {
        if (!checkIsFunctionCanBeCalled() || isScanning) {
            return
        }
        //  1、是否开启纯净搜索模式
        scanPureMode = pureModel
        //  2、执行搜索先优先执行停止搜索
        stopScan()
        //  3、执行搜索
        isScanning = true
        //  4、移除历史记录
        scanResultTemp.clear()
        //  5、创建搜索回调
        scanCallback = createScanCallBack()
        //  6、开始搜索
        bluetoothAdapter.bluetoothLeScanner?.startScan(null, scanSettings, scanCallback)
        sendLog(BleLoggerTag.d, "Start scan: success")
    }

    /**
     *  停止扫描
     */
    fun stopScan(isStartScan: Boolean = false) {
        if (!checkIsFunctionCanBeCalled()) {
            return
        }
        if (scanCallback == null) {
            sendLog(BleLoggerTag.d, "Stop scan: scan call back is null")
            return
        }
        //  停止时关闭纯净模式
        scanPureMode = false
        isScanning = false
        bluetoothAdapter.bluetoothLeScanner?.stopScan(scanCallback)
        scanCallback = null
        sendLog(BleLoggerTag.d, if (isStartScan) "Stop scan: checking if scan is already running, stopping it first if necessary" else "Stop scan: success")
    }

    /**
     * 主动连接指定 BLE 设备。
     *
     * 这个入口只表达一次前台连接请求：它负责校验请求、解析连接路由、必要时等待扫描命中，
     * 最后打开 GATT。断连后的长期自动回连由自动回连 supervisor 负责，不在这里调度。
     */
    @Synchronized
    fun connect(belongConfig: String, uuid: String, name: String, sn: String, isWaitingDevice: Boolean = false, afterUpgrade: Boolean = false, directConnect: Boolean = false) {
        // 1. 把散落的入参先收敛成请求对象，后续日志和路由判断都使用同一份上下文。
        val request = BleConnectRequest(
            belongConfig = belongConfig,
            uuid = uuid,
            name = name,
            sn = sn,
            afterUpgrade = afterUpgrade,
            directConnect = directConnect,
            isWaitingDevice = isWaitingDevice,
        )

        // 2. 入口级前置条件只处理“必然不能连接”的情况，避免后续步骤重复判空。
        val bleConfig = guardForegroundConnectRequest(request) ?: return

        // 3. 已绑定设备的手动点击如果已有长期 pending autoConnect，只提升同一 session 的
        // source/Gate 优先级并复用 GATT，不能取消 task 后再打开重复 GATT。
        if (autoReconnectSupervisor.promotePendingAttempt(request.uuid)) {
            sendLog(
                BleLoggerTag.d,
                "Start connect: ${request.uuid}, reuse and promote pending autoReconnect attempt",
            )
            return
        }

        // 4. 每次主动连接都清理上一轮预连接/升级脏状态，避免旧业务态污染新连接。
        //    同时只接管当前 UUID 的 passive autoReconnect task，不能全局 cancelAll，
        //    否则 G2/R1 多设备长期回连会互相取消。
        clearForegroundConnectMarkers(request)

        // 5. 解析 Android 连接路由：设备句柄、缓存设备、扫描名、系统 GATT connected 状态。
        val plan = resolveForegroundConnectPlan(request, bleConfig)
        logForegroundConnectPlan(plan)

        // 6. Android 协议栈缺少地址类型或稳定设备名时，先扫描刷新，再重新进入本函数。
        if (plan.shouldRefreshScanBeforeGatt()) {
            startScanRefreshBeforeForegroundConnect(plan)
            return
        }

        // 7. 绑定类设备必须有稳定 name；不能用 MAC 伪装 name，否则会污染 SN/name 匹配。
        if (failIfForegroundConnectNameMissing(plan)) {
            return
        }

        // 8. 前台连接看不到目标广播时，先入待扫描队列；系统已 connected 的设备会跳过这一步。
        if (enqueueScanThenForegroundConnectIfNeeded(plan)) {
            return
        }

        // 9. 准备本地 BleDevice 缓存，并处理 connecting/already connected/zombie 状态。
        val bleDevice = prepareDeviceForForegroundGatt(plan) ?: return

        // 10. 只有路由、扫描和缓存状态都通过后，才真正打开 Android GATT。
        openForegroundGatt(plan, bleDevice)
    }

    /**
     * 校验前台连接请求是否具备继续执行的基础条件。
     *
     * 该函数只处理必然失败的同步条件：蓝牙功能不可用、uuid 为空、配置不存在。
     */
    private fun guardForegroundConnectRequest(request: BleConnectRequest): BleConfig? {
        // 1. 蓝牙/权限不可用时必须给 Dart 一个终态。只 return 会让 UI 停在 connecting。
        if (!checkBleStatus()) {
            handleConnectState(request.uuid, request.name, BleConnectState.BLE_ERROR)
            sendLog(BleLoggerTag.e, "Start connect: ${request.uuid}, ble unavailable state=$currentBleState")
            return null
        }

        // 2. 配置缺失也是明确终态，不能被通用可调用检查静默吞掉。
        if (!checkBleConfigIsConfigured()) {
            handleConnectState(request.uuid, request.name, BleConnectState.NO_BLE_CONFIG_FOUND)
            return null
        }

        // 3. uuid 是 Android connectGatt 的最低身份信息，缺失时无法继续。
        if (request.uuid.isEmpty()) {
            handleConnectState(request.uuid, request.name, BleConnectState.EMPTY_UUID)
            sendLog(BleLoggerTag.e, "Start connect: ${request.uuid}, Empty uuid")
            return null
        }

        // 4. 配置决定扫描规则、私有服务和连接超时，不存在时必须明确失败。
        val bleConfig = bleConfigs.firstOrNull { it.name == request.belongConfig }
        if (bleConfig == null) {
            handleConnectState(request.uuid, request.name, BleConnectState.NO_BLE_CONFIG_FOUND)
            sendLog(BleLoggerTag.e, "Start connect: ${request.uuid}, no config")
            return null
        }

        return bleConfig
    }

    /**
     * 清理会影响新一轮前台连接的旧状态标记。
     *
     * 预连接状态来自上一轮 Dart 业务认证；升级状态只在 OTA 后的特殊连接路径保留。
     */
    private fun clearForegroundConnectMarkers(request: BleConnectRequest) {
        // 1. 新连接开始时，上一轮业务认证中的 preConnected 不再可信。
        preConnectedDevices.remove(request.uuid)

        // 2. 不在这里取消 autoReconnect owner。没有 pending handle 时允许普通首连继续，
        //    一旦本轮失败，已 arm 的长期 intent 仍能恢复 passive reconnect。

        // 3. 非升级连接需要退出升级态，避免普通连接继承 OTA 的断连/等待策略。
        if (!request.afterUpgrade && upgradeDevices.contains(request.uuid)) {
            upgradeDevices.remove(request.uuid)
        }
    }

    /**
     * 解析一次前台连接的 Android 路由信息。
     *
     * 这里集中处理所有只读查询：BluetoothDevice 句柄、本地缓存、扫描缓存、系统 GATT 状态。
     */
    private fun resolveForegroundConnectPlan(request: BleConnectRequest, bleConfig: BleConfig): BleConnectPlan {
        // 1. Android 允许按 MAC 构造 BluetoothDevice；是否真能连接由后续扫描/GATT 阶段验证。
        val remoteDevice = bluetoothAdapter.getRemoteDevice(request.uuid)

        // 2. 本地缓存用于复用已知设备名，也用于识别是否需要扫描刷新协议栈缓存。
        val cachedDevice = connectedDevices.firstOrNull { it.uuid == request.uuid }
        val cachedScanName = findCachedScanName(request.uuid, request.name, request.sn)

        // 3. 设备名优先级：系统名 > Dart 入参 name > 扫描缓存名 > 本地设备缓存名。
        val resolvedName = resolveBleDeviceName(
            remoteDevice.name,
            request.name,
            cachedScanName ?: cachedDevice?.name,
        )

        // 4. 系统已 GATT connected 的设备可能不广播，后续不能依赖扫描命中判断存在性。
        val isOsConnected = isSystemGattConnected(request.uuid)
        if (isOsConnected) {
            cachedDevice?.needsScanBeforeConnect = false
            sendLog(BleLoggerTag.d, "Start connect: ${request.uuid}, already connected at system GATT, direct connect without scan")
        }

        // 5. 缓存刷新和名称补齐拆开记录，日志定位时能看清为什么会先扫描。
        val needsScanForCache = cachedDevice?.needsScanBeforeConnect == true
        val needsScanForName = !request.isWaitingDevice && cachedDevice == null && resolvedName == null

        return BleConnectPlan(
            request = request,
            config = bleConfig,
            remoteDevice = remoteDevice,
            cachedDevice = cachedDevice,
            cachedScanName = cachedScanName,
            resolvedName = resolvedName,
            isOsConnected = isOsConnected,
            needsScanForCache = needsScanForCache,
            needsScanForName = needsScanForName,
        )
    }

    /**
     * 查询 Android 系统 GATT 层是否已经连接目标设备。
     *
     * 该判断用于 ANCS/系统自动回连类场景：设备已经在系统连接列表里，但因为不再广播而扫不到。
     */
    private fun isSystemGattConnected(uuid: String): Boolean {
        // 1. 系统查询可能因权限/状态异常抛错，失败时按未连接处理，保持旧路径兜底。
        return runCatching {
            bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
                .any { it.address.equals(uuid, ignoreCase = true) }
        }.getOrDefault(false)
    }

    /**
     * 输出前台连接路由日志。
     *
     * 路由日志必须保留 `resolvedName/cache/scan` 等关键信息，方便从 adb logcat 还原连接路径。
     */
    private fun logForegroundConnectPlan(plan: BleConnectPlan) {
        // 1. 第一条日志使用结构化 request.logMessage，便于 grep connect/request 类问题。
        sendLog(
            BleLoggerTag.d,
            plan.request.logMessage(plan.resolvedName, connectedDevices.size, scanResultTemp.size),
        )

        // 2. 第二条日志保留 Android 系统设备字段，便于识别 bond/type/name 异常。
        sendLog(
            BleLoggerTag.e,
            "Start connect: ${plan.request.uuid}, remote device = ${plan.remoteDevice.name}, resolved name = ${plan.resolvedName}, type = ${plan.remoteDevice.type}, state = ${plan.remoteDevice.bondState}",
        )
    }

    /**
     * 在打开 GATT 前启动一次扫描刷新。
     *
     * Android 某些断连/蓝牙开关恢复路径会丢失地址类型元数据，直接 connectGatt 容易静默失败。
     * 先扫描让系统协议栈重新看到广播，再回到 `connect(..., isWaitingDevice = true)`。
     */
    private fun startScanRefreshBeforeForegroundConnect(plan: BleConnectPlan) {
        val refreshKey = reconnectKey(plan.request.uuid)
        val refreshGeneration = ++scanRefreshGenerationCounter

        // 1. 本轮已经决定刷新扫描，旧的 needsScanBeforeConnect 标记可以消费掉。
        plan.cachedDevice?.needsScanBeforeConnect = false

        // 2. 同一 uuid 只允许一个 scan-refresh owner；旧任务必须取消，避免晚回调重入 connect。
        scanRefreshJobs.remove(refreshKey)?.cancel()
        scanRefreshGenerations[refreshKey] = refreshGeneration

        // 3. 扫描刷新期间先上报 connecting，避免 UI 在蓝牙恢复后长时间停留在 idle。
        handleConnectState(plan.request.uuid, plan.request.name, BleConnectState.CONNECTING)

        // 4. 开启扫描后延迟检查目标是否出现；未出现则 fast-fail，避免盲连 GATT 超时。
        startScan()
        val refreshJob = mainScope.launch {
            try {
                delay(10000)
                // generation 已变化说明用户取消、reset 或发起了新请求，本旧任务不能再动硬件。
                if (scanRefreshGenerations[refreshKey] != refreshGeneration) {
                    sendLog(BleLoggerTag.d, "Start connect: ${plan.request.uuid}, stale scan refresh skipped")
                    return@launch
                }
                stopScan()
                if (!isTargetVisibleInScan(plan.request.uuid, plan.request.name, plan.request.sn)) {
                    connectedDevices.removeAll { it.uuid == plan.request.uuid && it.myGatt == null }
                    handleConnectState(plan.request.uuid, plan.request.name, BleConnectState.NO_DEVICE_FOUND)
                    sendLog(BleLoggerTag.e, "Start connect: ${plan.request.uuid}, no device found after refresh scan")
                    return@launch
                }

                // 5. 重新进入 connect 前再次校验 owner；cancel 与 delay 恢复同帧交错时仍要挡住旧任务。
                if (scanRefreshGenerations[refreshKey] != refreshGeneration) {
                    sendLog(BleLoggerTag.d, "Start connect: ${plan.request.uuid}, scan refresh owner changed before reconnect")
                    return@launch
                }

                // 6. 重新进入 connect 时标记 isWaitingDevice=true，避免被自己设置的 connecting guard 拦住。
                connect(
                    plan.request.belongConfig,
                    plan.request.uuid,
                    plan.request.name,
                    plan.request.sn,
                    true,
                    plan.request.afterUpgrade,
                    plan.request.directConnect,
                )
            } finally {
                // 7. 只有当前 owner 才能清理 map，避免旧任务 finally 删除新任务 generation。
                if (scanRefreshGenerations[refreshKey] == refreshGeneration) {
                    scanRefreshGenerations.remove(refreshKey)
                    scanRefreshJobs.remove(refreshKey)
                }
            }
        }
        scanRefreshJobs[refreshKey] = refreshJob
        sendLog(BleLoggerTag.d, "Start connect: ${plan.request.uuid}, scan 3s to refresh BLE stack device info before connecting")
    }

    /**
     * 在设备名缺失时结束前台连接。
     *
     * 绑定类设备不能用 MAC 地址伪装 name，否则后续 name/SN 聚合和业务日志都会被污染。
     */
    private fun failIfForegroundConnectNameMissing(plan: BleConnectPlan): Boolean {
        // 1. 已经有稳定名称时可以继续后续连接流程。
        if (plan.resolvedName != null) {
            return false
        }

        // 2. 移除尚未打开 GATT 的临时设备缓存，避免下次连接误以为已有设备。
        connectedDevices.removeAll { it.uuid == plan.request.uuid && it.myGatt == null }
        handleConnectState(plan.request.uuid, plan.request.name, BleConnectState.BOUND_FAIL)
        sendLog(BleLoggerTag.e, "Start connect: ${plan.request.uuid}, device name missing, cannot bind")
        return true
    }

    /**
     * 必要时把前台连接请求放入待扫描队列。
     *
     * 该逻辑只服务主动连接：当前扫描窗口没看到目标时先等待广播出现；已被系统 GATT 连接的设备
     * 会跳过这里，因为系统连接状态下设备可能不会继续广播。
     */
    private fun enqueueScanThenForegroundConnectIfNeeded(plan: BleConnectPlan): Boolean {
        // 1. 先根据当前扫描缓存判断目标是否可见，再交给 plan 判断是否需要等待。
        val isVisible = isTargetVisibleInScan(plan.request.uuid, plan.request.name, plan.request.sn)
        if (!plan.shouldWaitForVisibleAdvertisement(isVisible)) {
            return false
        }

        // 2. 已有同 uuid 待扫描请求时直接复用，避免重复启动多个 timeout 协程。
        val alreadyPending = pendingScanConnects.any {
            it.uuid.equals(plan.request.uuid, ignoreCase = true)
        }
        if (alreadyPending) {
            return true
        }

        // 3. 进入 connecting 让 UI 展示“正在等待目标出现”，而不是仍停在可点击状态。
        handleConnectState(plan.request.uuid, plan.request.name, BleConnectState.CONNECTING)

        // 4. 入队的请求保留原始入参，扫描命中后会带 isWaitingDevice=true 重入 connect。
        pendingScanConnects.add(
            BlePendingScanConnect(
                belongConfig = plan.request.belongConfig,
                uuid = plan.request.uuid,
                name = plan.request.name,
                sn = plan.request.sn,
                afterUpgrade = plan.request.afterUpgrade,
                directConnect = plan.request.directConnect,
            ),
        )

        // 5. 如果当前没有扫描，启动扫描等待目标广播。
        if (!isScanning) {
            startScan()
        }

        // 6. 没有扫描结果时也要在 connectTimeout 后 fast-fail，避免 UI 永久 connecting。
        mainScope.launch {
            delay(plan.config.connectTimeout.toLong())
            expirePendingScanConnects()
        }
        sendLog(
            BleLoggerTag.d,
            "Start connect: ${plan.request.uuid}, scan-then-connect because target not seen in scan",
        )
        return true
    }

    /**
     * 准备本地 `BleDevice` 缓存，决定是否可以继续打开 GATT。
     *
     * 这里集中处理连接缓存的三种早退：正在连接、已经有可用 GATT、以及 connected 但 GATT 为空的
     * 僵尸状态。僵尸状态会继续往下连接，因为它代表上一次回调竞态没有正确落成 disconnected。
     */
    private fun prepareDeviceForForegroundGatt(plan: BleConnectPlan): BleDevice? {
        // 1. 经过前置校验后 resolvedName 必然非空；这里再次保护，避免未来改动绕过校验。
        val resolvedName = plan.resolvedName ?: return null

        // 2. 没有缓存时创建新的 BleDevice，并加入连接缓存列表。
        var bleDevice = connectedDevices.firstOrNull { it.uuid == plan.request.uuid }
        if (bleDevice == null) {
            bleDevice = plan.remoteDevice.toBleDevice(plan.config, resolvedName, plan.request.sn, 0)
            connectedDevices.add(bleDevice)
            return bleDevice
        }

        // 3. 普通重入遇到 connecting 直接返回；扫描补偿重入必须放行，否则会卡死在 connecting。
        if (bleDevice.connectState.isConnecting && !plan.request.isWaitingDevice) {
            sendLog(BleLoggerTag.d, "Start connect: ${plan.request.uuid}, device is connecting")
            return null
        }

        // 4. 已连接且 GATT 存在时，可能是热重启后的重复请求，也可能是系统已断但本地未清的僵尸态。
        if (bleDevice.connectState.isConnected && bleDevice.myGatt != null) {
            bleDevice.timeoutTimer?.cancel()
            bleDevice.timeoutTimer = null
            if (!plan.isOsConnected) {
                sendLog(BleLoggerTag.e, "Start connect: ${plan.request.uuid}, stale connected gatt not found in system connected list, force reconnect")
                bleDevice.releaseAndClear()
                return bleDevice
            }
            replayAlreadyConnectedForegroundState(plan, bleDevice)
            return null
        }

        // 5. connected 但 GATT 为空是旧断连竞态留下的僵尸态，需要继续打开新 GATT。
        if (bleDevice.isConnected && bleDevice.myGatt == null) {
            bleDevice.timeoutTimer?.cancel()
            bleDevice.timeoutTimer = null
            sendLog(BleLoggerTag.e, "Start connect: ${plan.request.uuid}, stale connected with no gatt, force reconnect")
        }

        return bleDevice
    }

    /**
     * 回放 native 已有连接状态给新一轮 Dart 前台连接请求。
     *
     * Flutter hot restart 会清空 Dart 内存状态，但 Android native 进程和 GATT 可能仍然存活。
     * 如果这里静默返回，Dart 侧恢复流程会一直等待本轮 `connectFinish/connected`，G2 串行连接
     * 也就卡在第一条腿。重复 connect 不是重新跑 GATT，而是把 native 已确认的状态重新推给
     * EventChannel，让 Dart 继续完成整机聚合或直接恢复详情页。
     */
    private fun replayAlreadyConnectedForegroundState(plan: BleConnectPlan, bleDevice: BleDevice) {
        // 1. 保留入参 name 的解析结果，避免旧缓存名为空时把空 name 推回 Dart。
        val replayName = plan.resolvedName ?: bleDevice.name

        // 2. 当前 GATT 已经可用，说明 characteristic/notify 缓存仍可写；回放现有业务状态即可。
        val replayState = bleDevice.connectState
        sendLog(
            BleLoggerTag.d,
            "Start connect: ${plan.request.uuid}, device is already connected, replay state = $replayState",
        )

        // 3. 复用统一状态出口，让超时清理、auto reconnect arm、EventChannel JSON 都保持一致。
        handleConnectState(plan.request.uuid, replayName, replayState)
    }

    /**
     * 打开 Android GATT 并进入连接超时状态。
     *
     * 这个函数是前台连接的最后一步；所有扫描、缓存、可见性和名称校验都必须在调用前完成。
     */
    private fun openForegroundGatt(plan: BleConnectPlan, bleDevice: BleDevice) {
        // 1. 默认主动连接使用 autoConnect=false，自动回连 passive 连接由 supervisor 独立处理。
        val connectCallBack = createConnectCallBack(
            plan.request.uuid,
            source = BleConnectSource.FOREGROUND,
            afterUpgrade = plan.request.afterUpgrade,
        )
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            plan.remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_2M)
        } else {
            plan.remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack)
        }

        // 2. 系统拒绝创建 GATT 时，本 attempt 必须终止并释放 Gate generation。
        if (gatt == null) {
            handleConnectState(
                plan.request.uuid,
                plan.resolvedName ?: bleDevice.name,
                BleConnectState.SYSTEM_ERROR,
                source = BleConnectSource.FOREGROUND,
            )
            cancelConnectionAdmission(plan.request.uuid, reason = "connectGatt returned null")
            return
        }

        // 3. GATT 句柄必须立即写回缓存，后续 service/notify 回调都按 uuid 找这条 session。
        bleDevice.update(gatt)

        // 4. RSSI 读取不参与连接成功判定，只作为调试/展示信号值来源。
        gatt?.readRemoteRssi()

        // 5. Gate 排队时间不计入 connectTimeout；timeout 只在 startGrantedGattPipeline 中启动。
        handleConnectState(
            plan.request.uuid,
            plan.resolvedName ?: bleDevice.name,
            BleConnectState.CONNECTING,
            source = BleConnectSource.FOREGROUND,
        )
        sendLog(
            BleLoggerTag.d,
            "Start connect: ${plan.request.uuid} connecting, belong config = ${bleDevice.belongConfig}, after upgrade = ${plan.request.afterUpgrade}",
        )
    }

    /**
     *  开启/续期连接超时定时器。
     *
     *  预连接(协议层鉴权进行中)时给一次有界宽限期(isAuthGrace=true)，而不是永久豁免：
     *  永久豁免会让 Dart 端鉴权异常/挂起(deviceConnected 永不到达)的设备永久停在
     *  connectFinish，App UI 一直显示"连接中"且无法自愈。
     */
    private fun startConnectTimeout(
        bleConfig: BleConfig,
        uuid: String,
        name: String,
        afterUpgrade: Boolean,
        isAuthGrace: Boolean = false,
        admission: BleConnectionAdmission? = currentAdmissions[reconnectKey(uuid)],
    ) {
        val timeoutTimer = Timer()
        timeoutTimer.schedule(object : TimerTask() {
            override fun run() {
                // Gate owner 已变化说明本 timer 属于旧 generation/session，必须静默退出。
                if (admission != null && currentAdmissionFor(admission) == null) {
                    return
                }
                //  已连接：仅清理定时器
                val device = connectedDevices.firstOrNull { it.uuid == uuid }
                if (device?.isConnected == true) {
                    device.timeoutTimer = null
                    return
                }
                //  预连接(鉴权进行中)：续一次有界宽限期，而非永久豁免。
                if (preConnectedDevices.contains(uuid) && !isAuthGrace) {
                    sendLog(BleLoggerTag.d, "Start connect: $uuid, pre-connected, start bounded auth grace")
                    startConnectTimeout(
                        bleConfig,
                        uuid,
                        name,
                        afterUpgrade = false,
                        isAuthGrace = true,
                        admission = admission,
                    )
                    return
                }
                //  宽限到期仍未连接(或本就不是预连接) → 强制超时，避免永久卡在 connecting。
                sendLog(BleLoggerTag.e, "Start connect: $uuid, connect time out${if (isAuthGrace) " (auth grace expired)" else ""}")
                //  1、超时断连则记录断连状态，避免系统断连导致重复执行断连状态
                disconnectingDevices.removeAll {
                    it.first == uuid
                }
                disconnectingDevices.add(Pair(uuid, BleConnectState.TIMEOUT))
                //  2、执行超时断连
                if (admission != null) {
                    terminateConnectionAdmission(
                        expectedAdmission = admission,
                        gatt = device?.myGatt,
                        fallbackName = name,
                        state = BleConnectState.TIMEOUT,
                    )
                } else {
                    handleConnectState(
                        uuid,
                        name,
                        BleConnectState.TIMEOUT,
                        source = BleConnectSource.UNKNOWN,
                    )
                }
            }
        }, bleConfig.connectTimeout.toLong() + (if (afterUpgrade) bleConfig.upgradeSwapTime.toLong() else 0))
        //  把定时器挂到设备上，连接成功(handleConnectState .CONNECTED)时会被 cancel 清理。
        val bleDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        bleDevice?.timeoutTimer?.cancel()
        bleDevice?.timeoutTimer = timeoutTimer
    }

        /**
     *  设置设备预连接
     */
    fun setPreConnected(uuid: String) {
        if (uuid.isEmpty()) {
            return
        }
        preConnectedDevices.add(uuid)
        sendLog(BleLoggerTag.d, "Set $uuid pre-connected")
    }

    /**
     *  主动设置连接成功
     */
    fun setConnected(uuid: String) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        if (!preConnectedDevices.contains(uuid)) {
            sendLog(BleLoggerTag.e, "Set $uuid connected failed, not pre-connected")
            return
        }
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        val admission = currentAdmissions[reconnectKey(uuid)]
        // 策略校验不带 Kotlin contract；先显式绑定非空值，避免后续 source/generation
        // 读取依赖不可靠的 smart-cast，同时维持 unknown/0 fail-closed 约束。
        val acceptedAdmission = admission ?: run {
            sendLog(BleLoggerTag.e, "Set $uuid connected failed, no epoch-accepted admission")
            return
        }
        // 业务 connected 后 Gate 会释放，所以此刻必须已经持有可被 Dart epoch guard 接受的
        // admission。拒绝 unknown/0，确保蓝牙关闭时总能从 current/business session 取到终态。
        if (!BleBluetoothOffTerminalMetadataPolicy.isEpochAccepted(acceptedAdmission)) {
            sendLog(BleLoggerTag.e, "Set $uuid connected failed, no epoch-accepted admission")
            return
        }
        sendLog(BleLoggerTag.d, "Set $uuid connected")
        //  移除预连接状态
        preConnectedDevices.remove(uuid)
        handleConnectState(
            uuid,
            connectedDevice?.name ?: "",
            BleConnectState.CONNECTED,
            source = acceptedAdmission.source,
            generation = acceptedAdmission.generation,
        )
        // connectFinish 仍持有 Gate；只有业务确认 connected 才允许下一 endpoint 开始 pipeline。
        completeBusinessConnectionAdmission(uuid)
    }

    /**
     * 断连设备
     */
    fun disconnect(uuid: String, removeBond: Boolean = false) {
        sendLog(BleLoggerTag.d, "Star disconnect: $uuid by user")
        businessConnectedGattSessions.remove(reconnectKey(uuid))
        // 用户主动断开就是取消长期回连意图；removeBond 只额外清系统绑定。
        removePersistedReconnectTarget(uuid)
        autoReconnectSupervisor.cancel(uuid, reason = "user disconnect")
        // 用户主动断开必须取消“扫描刷新后重入 connect”的本地延迟任务。
        cancelScanRefresh(uuid)
        cancelPendingScanConnect(uuid)
        //  1、移除预连接状态
        preConnectedDevices.remove(uuid)
        //  2、获取已连接设备
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        //  3、先完整断开/关闭旧 GATT，再释放 Gate 让下一设备启动 pipeline。
        handleConnectState(uuid, connectedDevice?.name ?: "", BleConnectState.DISCONNECT_BY_USER, removeBond)
        cancelConnectionAdmission(uuid, reason = "user disconnect")
    }

    /**
     * OTA 成功后 firmware reboot 的专用断开。
     *
     * 它与 [disconnect] 的唯一关键差异是：不撤销 persisted/native autoReconnect owner。
     * 先冻结本次业务 connected 的 admission metadata，再上报可被 Dart epoch guard 接受
     * 的系统断连；本次 terminal 不调度 native retry，避免与上层 afterUpgrade activation
     * 在设备尚未 reboot 完成时竞争 GATT。
     */
    fun disconnectForOtaReboot(uuid: String, name: String = "") {
        val device = connectedDevices.firstOrNull { candidate ->
            candidate.uuid.equals(uuid, ignoreCase = true) ||
                (name.isNotBlank() && candidate.name == name)
        }
        if (device == null) {
            sendLog(BleLoggerTag.e, "OTA reboot disconnect: $uuid-$name, no connected device cache")
            return
        }
        val key = reconnectKey(device.uuid)
        val acceptedAdmission = BleBluetoothOffTerminalMetadataPolicy.resolve(
            currentAdmission = currentAdmissions[key],
            businessConnectedAdmission = businessConnectedGattSessions[key]?.admission,
        ) ?: run {
            // 不能把 unknown/0 发给 Dart：它会被 epoch guard 拒绝并留下假连接。OTA
            // 收尾只允许业务已确认 connected 的 endpoint 进入，因此这属于不变量破坏。
            sendLog(BleLoggerTag.e, "OTA reboot disconnect: ${device.uuid}, missing epoch-accepted admission")
            return
        }
        markOtaRebootDisconnectSuppression(device.uuid)
        preConnectedDevices.remove(device.uuid)
        handleConnectState(
            device.uuid,
            device.name,
            BleConnectState.DISCONNECT_FROM_SYS,
            source = acceptedAdmission.source,
            generation = acceptedAdmission.generation,
            scheduleAutoReconnect = false,
        )
        sendLog(BleLoggerTag.d, "OTA reboot disconnect: ${device.uuid}, owner preserved")
    }

    /** 只屏蔽本次主动 close 的迟到 callback；10 秒内没有回调则自动失效，不能污染新会话。 */
    private fun markOtaRebootDisconnectSuppression(uuid: String) {
        val key = reconnectKey(uuid)
        otaRebootDisconnectSuppressions.add(key)
        mainScope.launch {
            delay(10_000)
            otaRebootDisconnectSuppressions.remove(key)
        }
    }

    private fun consumeOtaRebootDisconnectSuppression(uuid: String): Boolean =
        otaRebootDisconnectSuppressions.remove(reconnectKey(uuid))

    /**
     * 中性释放单个 endpoint 的 native runtime，不删除 persisted reconnect owner/config。
     *
     * even_connect 的 dispose/reset 使用本入口；用户点击断开仍必须走 [disconnect]，两种
     * 语义不能用 bool 混合，否则调用方很容易误删长期自动回连授权。
     */
    @Synchronized
    fun releaseDevice(uuid: String, name: String = "") {
        val taskEndpoints = autoReconnectSupervisor.endpointsMatching(uuid, name)
        val matchingDevices = connectedDevices.filter { device ->
            (uuid.isNotBlank() && device.uuid.equals(uuid, ignoreCase = true)) ||
                (name.isNotBlank() && device.name == name)
        }
        val matchingPendingEndpoints = pendingScanConnects.filter { pending ->
            (uuid.isNotBlank() && pending.uuid.equals(uuid, ignoreCase = true)) ||
                (name.isNotBlank() && pending.name == name)
        }.map { it.uuid }
        val endpointIds = (taskEndpoints + matchingDevices.map { it.uuid } +
            matchingPendingEndpoints + listOf(uuid))
            .filter { it.isNotBlank() }
            .toSet()
        if (endpointIds.isEmpty()) {
            return
        }
        val endpointKeys = endpointIds.map(::reconnectKey).toSet()
        val admissionSessions = admittedGattSessions.values.filter {
            reconnectKey(it.admission.endpointId) in endpointKeys
        }
        val businessSessions = businessConnectedGattSessions
            .filterKeys { it in endpointKeys }
            .values

        // 1. 先失效 manager + Gate owner/generation，随后所有迟到 GATT callback 都 fail closed。
        currentAdmissions.keys
            .filter { it in endpointKeys }
            .forEach { currentAdmissions.remove(it) }
        admissionSessions.forEach { admittedGattSessions.remove(it.admission.sessionId) }
        endpointKeys.forEach { businessConnectedGattSessions.remove(it) }
        endpointIds.forEach { endpointId ->
            val key = reconnectKey(endpointId)
            connectionAttemptGenerations[key] = nextConnectionGeneration(
                connectionAttemptGenerations[key] ?: 0L,
            )
        }
        val next = connectionAdmissionGate.cancelEndpoints(endpointIds)

        // 2. 取消该 endpoint 所有未来 runtime 入口，但刻意不调用 removePersistedReconnectTarget。
        taskEndpoints.forEach { autoReconnectSupervisor.cancel(it, reason = "neutral releaseDevice") }
        endpointIds.forEach { endpointId ->
            cancelScanRefresh(endpointId)
            preConnectedDevices.remove(endpointId)
            upgradeDevices.remove(endpointId)
            sendCmdQueues.remove(reconnectKey(endpointId))
        }
        pendingScanConnects.removeAll { pending ->
            reconnectKey(pending.uuid) in endpointKeys ||
                (name.isNotBlank() && pending.name == name)
        }
        disconnectingDevices.removeAll { reconnectKey(it.first) in endpointKeys }
        scanResultTemp.removeAll { device ->
            reconnectKey(device.uuid) in endpointKeys ||
                (name.isNotBlank() && device.name == name)
        }

        // 3. map 失效后关闭 GATT；device 与 admission/business session 可能引用同一句柄。
        val deviceGattHandles = matchingDevices.mapNotNull { it.myGatt }
        matchingDevices.forEach { device ->
            device.releaseAndClear()
            device.connectState = BleConnectState.NONE
        }
        connectedDevices.removeAll { device ->
            reconnectKey(device.uuid) in endpointKeys ||
                (name.isNotBlank() && device.name == name)
        }
        (admissionSessions.map { it.gatt } + businessSessions.map { it.gatt })
            .distinctBy { System.identityHashCode(it) }
            .filter { gatt -> deviceGattHandles.none { it === gatt } }
            .forEach { gatt ->
                runCatching { gatt.disconnect() }
                runCatching { gatt.close() }
            }

        next?.let { startGrantedGattPipeline(it) }
        sendLog(
            BleLoggerTag.d,
            "Release device runtime: endpoints=$endpointIds, persisted reconnect owner preserved",
        )
    }

    /**
     *
     *  发送数据
     *
     *  @param uuid 发送指令设备
     *  @param data 指令数据
     *  @param psType 私有服务类型
     *
     */
    fun sendCmd(uuid: String, data: ByteArray, psType: Int = 0) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        if (upgradeDevices.contains(uuid) && psType != 1) {
            sendLog(BleLoggerTag.e, "Send cmd: $uuid, Cannot send commands during upgrade")
            return
        }
        val key = reconnectKey(uuid)
        val queue = sendCmdQueues.getOrPut(key) { ConcurrentLinkedQueue() }
        val shouldStart = queue.isEmpty()
        queue.add(BleCmd(uuid, psType, data, false))
        if (shouldStart) {
            writeNextCommand(uuid)
        }
    }
    
    /**
     * 不等待写入结果的指令发送
     * 
     * - 注意，使用的是要尽量不要跟sendCmd一起使用，避免204响应导致数据丢失
     */
    fun sendCmdNoWait(uuid: String, data: ByteArray, psType: Int = 0) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        connectedDevices.firstOrNull { it.uuid == uuid }?.writeCharacteristic(data, psType)
        sendLog(BleLoggerTag.d, "Send cmd - no wait: $uuid, type=$psType, data length=${data.size}")
    }

    /**
     *  进入升级模式
     */
    fun enterUpgradeState(uuid: String) {
        if (upgradeDevices.contains(uuid)) {
            return
        }
        upgradeDevices.add(uuid)
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        handleConnectState(uuid, connectedDevice?.name ?: "", BleConnectState.UPGRADE)
        sendLog(BleLoggerTag.d, "EnterUpgradeState: $uuid Into upgrade state")
    }

    /**
     *  退出升级模式
     */
    fun quiteUpgradeState(uuid: String) {
        if (!upgradeDevices.contains(uuid)){
            return
        }
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        handleConnectState(uuid, connectedDevice?.name ?: "", BleConnectState.CONNECTED)
        upgradeDevices.remove(uuid)
        sendLog(BleLoggerTag.d, "QuiteUpgradeState: $uuid had quite upgrade state")
    }

    /**
     * 清除连接缓存
     */
    @Synchronized
    fun cleanConnectCache() {
        teardownConnectionRuntime(reason = "cleanConnectCache")
        // clean cache 是显式破坏入口，必须同时清磁盘目标，避免下次进程恢复又自动回连。
        clearPersistedReconnectTargets()
    }

    /**
     * 释放一次 BLE runtime session，但不触碰持久化 reconnect owner/config 偏好。
     * resetBle 与 cleanConnectCache 共用这条链路，避免两种 teardown 在 Gate/GATT 清理上分叉。
     */
    private fun teardownConnectionRuntime(reason: String) {
        // 1. 先快照所有 runtime GATT，再让 manager map 与 Gate 一次性失效。之后任何
        // active/waiting/pre-physical 迟到 callback 都无法通过 current admission 校验。
        val deviceGattHandles = connectedDevices.mapNotNull { it.myGatt }
        val admissionGattHandles = admittedGattSessions.values.map { it.gatt }
        val businessGattHandles = businessConnectedGattSessions.values.map { it.gatt }
        connectionAdmissionGate.invalidateAllAndReset()
        currentAdmissions.clear()
        admittedGattSessions.clear()
        businessConnectedGattSessions.clear()
        connectionAttemptGenerations.replaceAll { _, generation ->
            nextConnectionGeneration(generation)
        }

        // 2. 停掉所有会在未来重新打开连接的 owner/delay，再释放 connectedDevices GATT。
        cancelAllScanRefresh()
        pendingScanConnects.clear()
        autoReconnectSupervisor.cancelAll(reason = reason)
        connectedDevices.forEach { device ->
            device.releaseAndClear()
            device.connectState = BleConnectState.NONE
        }
        (admissionGattHandles + businessGattHandles)
            .distinctBy { System.identityHashCode(it) }
            .filter { gatt -> deviceGattHandles.none { it === gatt } }
            .forEach { gatt ->
                runCatching { gatt.disconnect() }
                runCatching { gatt.close() }
            }

        // 3. GATT session 相关的业务缓存同样失效，不能泄漏到下一次手动连接。
        sendCmdQueues.clear()
        disconnectingDevices.clear()
        preConnectedDevices.clear()
    }

    /**
     * 重置
     */
    @Synchronized
    fun reset() {
        stopScan()
        // resetBle 是中性 runtime teardown，不能复用 disconnect/clean 的硬取消语义；
        // 否则会删除 persisted reconnect owner，破坏上层 reset 后继续 autoReconnect 的契约。
        teardownConnectionRuntime(reason = "reset")
        connectedDevices.clear()
        scanResultTemp.clear()
        upgradeDevices.clear()
        sendCmdQueues.clear()
        disconnectingDevices.clear()
        preConnectedDevices.clear()
        sendLog(BleLoggerTag.d, "Reset: success")
    }

    /**
     * 取消单个 scan-refresh 延迟任务。
     *
     * 这个任务会在 delay 后重新调用 connect，因此用户主动断开/移除时必须显式撤销 owner。
     */
    private fun cancelScanRefresh(uuid: String) {
        // 1. generation 先移除，挡住已经恢复但尚未执行 connect 的旧协程。
        val key = reconnectKey(uuid)
        scanRefreshGenerations.remove(key)

        // 2. 再 cancel Job，释放 delay 挂起的协程。
        scanRefreshJobs.remove(key)?.cancel()
    }

    /**
     * 取消全部 scan-refresh 延迟任务。
     *
     * reset/clean cache 会重置本地连接所有权，所有旧延迟任务都必须失效。
     */
    private fun cancelAllScanRefresh() {
        // 1. 先清 generation，确保竞态恢复的旧 Job 只能观察到失效 owner。
        scanRefreshGenerations.clear()

        // 2. 再逐个取消 Job 并清空表。
        scanRefreshJobs.values.forEach { it.cancel() }
        scanRefreshJobs.clear()
    }

    /**
     * 取消等待扫描命中的前台连接请求。
     *
     * 这类请求还没有 GATT，但已经让 UI 进入 connecting；用户主动断开时不能等 timeout 才释放。
     */
    private fun cancelPendingScanConnect(uuid: String) {
        // 1. 仅按 uuid 取消，避免同名多设备互相影响。
        pendingScanConnects.removeAll { it.uuid.equals(uuid, ignoreCase = true) }

        // 2. 没有待连接请求时停止扫描，释放硬件扫描资源。
        if (pendingScanConnects.isEmpty()) {
            stopScan()
        }
    }

    /**
     * 释放/销毁 BleManager
     *
     * 在Flutter引擎分离时调用，以释放所有资源，确保单例可以被重新初始化。
     */
    fun release() {
        // 1. 调用现有的 reset 逻辑，断开所有连接并清空队列
        reset()
        // 2. 注销蓝牙状态监听器，防止内存泄漏
        bleStateListener?.unregister()
        bleStateListener = null
        // 3. 取消所有正在进行的协程任务
        if (this::mainScope.isInitialized) {
            mainScope.cancel()
        }
        // 4. 释放 Context 引用
        weakContext?.clear()
        weakContext = null
        sendLog(BleLoggerTag.d, "Release: BleManager completely released")
    }


    /// =========== Method: Private

    /**
     *  检查是否添加了蓝牙配置
     */
    private fun checkBleConfigIsConfigured(): Boolean {
        val commonPs = bleConfigs.firstOrNull()?.privateServices?.firstOrNull()
        if (commonPs == null) {
            sendLog(BleLoggerTag.e, "CheckBleConfigIsConfigured: Bluetooth configuration has not been configured or not setting private service yet")
            return false
        }
        if (commonPs.type != 0) {
            sendLog(BleLoggerTag.e, "CheckBleConfigIsConfigured: The first type of private service must be 0, where 0 represents the basic private service.")
            return false
        }
        return true
    }

    /**
     * 检查蓝牙是否可用
     */
    private fun checkBleStatus(): Boolean {
        if (currentBleState != 5) {
            sendLog(BleLoggerTag.e, "CheckIsFunctionCanBeCalled: ble status = $currentBleState")
            return false
        }
        return true
    }

    /**
     * 检查是否可以调用方法
     *
     * @exception 1、检查蓝牙状态，2、检查是否启用蓝牙配置
     */
    private fun checkIsFunctionCanBeCalled(): Boolean {
        if (!checkBleStatus()) {
            return false
        }
        if (!checkBleConfigIsConfigured()) {
            return false
        }
        return true
    }

    /**
     * 检查系统蓝牙是否开启（避免在蓝牙关闭/崩溃时触发 Binder 调用导致 DeadObjectException）
     */
    private fun isBluetoothEnabled(): Boolean = try {
        bluetoothAdapter.isEnabled
    } catch (_: Exception) {
        false
    }

    /**
     * 在蓝牙关闭 teardown 前收集所有业务连接终态。
     *
     * Gate 尚未释放的 endpoint 优先复用 current admission；已执行 deviceConnected 的
     * endpoint 则复用 businessConnectedGattSessions 保存的 exact admission。setConnected
     * 已建立“业务 connected 必有有效 admission”的不变量；这里若缺失必须显式失败，不能把
     * 断连静默降级为 unknown/0 或直接跳过。
     */
    private fun captureBluetoothOffTerminalSnapshots(): List<BluetoothOffTerminalSnapshot> =
        connectedDevices
            .filter { it.connectState.isConnected }
            .map { device ->
                val key = reconnectKey(device.uuid)
                val admission = checkNotNull(
                    BleBluetoothOffTerminalMetadataPolicy.resolve(
                        currentAdmission = currentAdmissions[key],
                        businessConnectedAdmission = businessConnectedGattSessions[key]?.admission,
                    ),
                ) {
                    "Bluetooth off terminal invariant violated for ${device.uuid}: missing epoch-accepted admission"
                }
                BluetoothOffTerminalSnapshot(
                    uuid = device.uuid,
                    name = device.name,
                    source = admission.source,
                    generation = admission.generation,
                )
            }

    /**
     * 创建蓝牙状态监听器
     */
    private fun createBleStateListener(): BluetoothStateCallback = object : BluetoothStateCallback {
        override fun onBluetoothStateChanged(state: Int) {
            //  监听获取蓝牙开关
            bleState = when (state) {
                //  蓝牙关闭
                BluetoothAdapter.STATE_OFF -> 4
                //  蓝牙开启
                BluetoothAdapter.STATE_ON -> 5
                //  错误处理
                BluetoothAdapter.ERROR -> 0
                //  不处理：正在关闭/打开
                //  BluetoothAdapter.STATE_TURNING_OFF
                //  BluetoothAdapter.STATE_TURNING_ON
                else -> return
            }
            if (bleState != 5) {
                // transport teardown 会清空 Gate/current/business session；必须先冻结每个
                // 业务已连接 endpoint 的 source/generation，避免后续终态事件退化为 unknown/0。
                val transportOffTerminalSnapshots = captureBluetoothOffTerminalSnapshots()
                autoReconnectSupervisor.pauseForBluetoothOff()
                // 蓝牙关闭先快照并关闭 active/queued/pre-physical GATT。只清 map 会留下
                // binder handle，迟到 services/descriptor callback 仍可能与蓝牙恢复后的新 pipeline 竞态。
                val admissionGattHandles = admittedGattSessions.values
                    .map { it.gatt }
                    .distinctBy { System.identityHashCode(it) }
                admissionGattHandles.forEach { gatt ->
                    runCatching { gatt.disconnect() }
                    runCatching { gatt.close() }
                }
                val admissionEndpoints = currentAdmissions.keys.toSet()
                connectedDevices
                    .filter { reconnectKey(it.uuid) in admissionEndpoints }
                    .forEach { it.releaseAndClear() }

                // 句柄 teardown 后再原子暂停 Gate 并失效所有 generation/session/callback。
                connectionAdmissionGate.suspendAndReset()
                currentAdmissions.clear()
                admittedGattSessions.clear()
                businessConnectedGattSessions.clear()
                connectionAttemptGenerations.replaceAll { _, generation -> generation + 1L }
                //  清除所有升级设备数据，避免执行OTA退出时出现状态回连问题
                upgradeDevices.clear()
                //  系统级蓝牙关闭：把所有已连接设备标记为 DISCONNECT_FROM_SYS（系统断连），
                //  让 even_connect 的 EvenDeviceReconnectMixin 能在 BLE 恢复后自动接管重连。
                //  ⚠️ 不能复用 disconnect()，它发的是 DISCONNECT_BY_USER（用户主动断），
                //     重连白名单只包含 disconnectFromSys / serviceFail / charsFail / timeout，
                //     用户主动断不会触发重连，会导致 BLE 关再开后只剩部分设备被业务层手动拉起、
                //     其它设备（典型如戒指）永远不重连。
                //  ⚠️ 这里必须用 connectState.isConnected（含 CONNECTED + UPGRADE），
                //     不能用 BleDevice.isConnected（只判 CONNECTED）。
                //     OTA 升级中的设备 connectState = UPGRADE，若用后者会被漏掉，
                //     导致蓝牙关闭时不释放其 GATT。蓝牙重开后该 GATT 的 binder 已死，
                //     业务层仍以为"已连接"继续发指令 → android.os.DeadObjectException 刷屏。
                transportOffTerminalSnapshots.forEach { snapshot ->
                    // 与 disconnect() 一致：清理预连接标记，避免残留状态影响下次重连判定。
                    // 显式传入 teardown 前冻结的 metadata，绝不能依赖已被清空的 runtime 表默认值。
                    preConnectedDevices.remove(snapshot.uuid)
                    handleConnectState(
                        snapshot.uuid,
                        snapshot.name,
                        BleConnectState.DISCONNECT_FROM_SYS,
                        source = snapshot.source,
                        generation = snapshot.generation,
                    )
                }
            } else {
                connectionAdmissionGate.resume()
                autoReconnectSupervisor.resumeAfterBluetoothOn()
            }
            sendLog(BleLoggerTag.d, "Ble statue listener: Original state = $state, to even state = $bleState")
            //  检查蓝牙权限
            checkBluetoothPermission()
        }

        override fun onDeviceBondStateChanged(device: BluetoothDevice, isBonded: Boolean) {
            val connectedDevice = findConnectedDevice(device.address)
            //  1、不处理非连接设备的绑定状态
            if (connectedDevice == null) {
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} not connected device")
                return
            }
            //  2、如果没有绑定成功就结束
            if (!isBonded) {
                //  - 存在已经配对过的设备，蓝牙密钥信息丢失，
                //  - 发起连接会立马返回断连或则绑定失败，导致执行了断连，此时超时连接定时器已经关闭
                //  - 但是此时服务搜索又可以执行，会使连接进入连接中，一直无法退出
                //  - 所以阻断执行boundFail的流程，等待超时关闭连接
                if (connectedDevice.connectState.isConnecting || connectedDevice.connectState.isDisconnected) {
                    return
                }
                //  - 只有连接成功后才执行搜索，确保再次连接设备时设备能被重新刷新，避免连接旧的连接信息
                mainScope.launch {
                    startScan()
                }
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} unable to bind")
                handleConnectState(connectedDevice.uuid, connectedDevice.name, BleConnectState.BOUND_FAIL)
                return
            }
            //  3、如果眼镜已经连接了就不再执行绑定
            if (connectedDevice.connectState.isConnected) {
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} bind success")
                return
            }
            //  4、检查当前设备连接状态，如果出现异常就不处理
            if (connectedDevice.connectState.isError) {
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} is ${connectedDevice.connectState}, bound failure")
                handleConnectState(connectedDevice.uuid, connectedDevice.name, BleConnectState.BOUND_FAIL)
                return
            }
            //  5、主动绑定时，需要进入CONNECT_FINISH流程，如果是眼镜主动绑定，则默认进入CONNECT_FINISH
            if (connectedDevice.belongConfig.initiateBinding) {
                handleConnectState(connectedDevice.uuid, connectedDevice.name, BleConnectState.CONNECT_FINISH)
            }
            sendLog(BleLoggerTag.d, "Ble status listener - bond state: ${device.address} is bonded, state = ${connectedDevice.connectState}, finish connect")
        }
    }

    /// 当前扫描缓存中是否已出现目标设备。
    private fun isTargetVisibleInScan(uuid: String, name: String, sn: String): Boolean {
        return synchronized(scanResultTemp) {
            scanResultTemp.any { device ->
                device.uuid.equals(uuid, ignoreCase = true) ||
                    (name.isNotEmpty() && device.name == name) ||
                    (sn.isNotEmpty() && device.sn == sn)
            }
        }
    }

    /// 从本轮扫描缓存找稳定 name，用于 Android getRemoteDevice(address).name 为空时继续连接。
    private fun findCachedScanName(uuid: String, name: String, sn: String): String? {
        return synchronized(scanResultTemp) {
            scanResultTemp.firstOrNull { device ->
                device.uuid.equals(uuid, ignoreCase = true) ||
                    (name.isNotEmpty() && device.name == name) ||
                    (sn.isNotEmpty() && device.sn == sn)
            }?.name?.takeIf { it.isNotBlank() }
        }
    }

    private fun reconnectKey(uuid: String): String = uuid.lowercase()

    /** generation 只增不减并在 Long 上限饱和，避免极端长运行溢出后旧 callback 复活。 */
    private fun nextConnectionGeneration(current: Long): Long =
        if (current == Long.MAX_VALUE) Long.MAX_VALUE else current + 1L

    /**
     * 记录 Android native 自动回连事件。
     *
     * EventChannel 可能尚未恢复监听，因此事件通过 `BleReconnectStore` 先进入持久化缓冲。
     */
    private fun recordAutoReconnectEvent(
        type: String,
        uuid: String = "",
        name: String = "",
        detail: String = "",
    ) {
        // 1. Manager 只提供当前 context 和事件内容，具体存储格式由仓库负责。
        reconnectStore.recordEvent(
            context = weakContext?.get(),
            type = type,
            uuid = uuid,
            name = name,
            detail = detail,
        )
    }

    /**
     * 读取并清空 Android native 自动回连事件。
     *
     * Dart 侧可在启动后主动 drain，用来补读后台恢复期间错过的 native 事件。
     */
    fun drainAutoReconnectEvents(): List<Map<String, Any>> {
        // 1. 仓库负责 drain 语义，manager 不关心 SharedPreferences key 和 JSON 结构。
        return reconnectStore.drainEvents(weakContext?.get())
    }

    /**
     * 保存当前 BLE 配置快照。
     *
     * 自动回连/进程恢复场景可能早于 Dart 重新 initConfigs，因此 native 保留一份轻量配置。
     */
    private fun persistConfigs(configs: List<BleConfig>) {
        // 1. 配置序列化细节下沉到仓库，manager 只表达“保存当前配置”。
        reconnectStore.persistConfigs(weakContext?.get(), configs)
    }

    /**
     * 在当前配置为空时恢复持久化配置。
     *
     * 只有 native 自动回连早于 Dart initConfigs 时才会真正使用恢复结果。
     */
    private fun restorePersistedConfigsIfNeeded() {
        // 1. Dart 已经下发配置时，内存配置始终优先。
        if (bleConfigs.isNotEmpty()) {
            return
        }

        // 2. 仓库恢复失败返回 null，manager 保持空配置并等待 Dart initConfigs。
        val restoredConfigs = reconnectStore.restoreConfigs(weakContext?.get()) ?: return
        bleConfigs = restoredConfigs
        sendLog(BleLoggerTag.d, "Auto reconnect: restored ${restoredConfigs.size} persisted config(s)")
    }

    /**
     * 持久化一个业务已确认 connected 的设备。
     *
     * 只有 deviceConnected 后才会调用这里，避免 GATT ready 但业务认证失败的设备进入自动回连。
     */
    private fun persistReconnectTarget(device: BleDevice) {
        // 1. 仓库负责去重和磁盘格式，manager 只提供当前设备身份。
        reconnectStore.upsertTarget(weakContext?.get(), device)
        sendLog(BleLoggerTag.d, "Auto reconnect: ${device.uuid}, persisted native reconnect target")
    }

    /**
     * 移除单个持久化回连目标。
     *
     * 用户主动断开时必须清理目标，否则后续系统断连可能重新恢复连接。
     */
    private fun removePersistedReconnectTarget(uuid: String) {
        // 1. 空 uuid 由仓库保持幂等；manager 不再参与 JSON 列表过滤。
        reconnectStore.removeTarget(weakContext?.get(), uuid)
    }

    /**
     * 清空全部持久化回连目标。
     *
     * reset/remove-all 语义要求彻底取消 native 自动回连意图。
     */
    private fun clearPersistedReconnectTargets() {
        // 1. 只清目标，不清配置快照；配置快照仍可用于下一次 init 前恢复。
        reconnectStore.clearTargets(weakContext?.get())
    }

    /// 待扫描连接请求是否与扫描结果匹配。
    private fun matchesPendingScan(device: BleDevice, pending: BlePendingScanConnect): Boolean {
        return pending.uuid.equals(device.uuid, ignoreCase = true) ||
            (pending.name.isNotEmpty() && pending.name == device.name) ||
            (pending.sn.isNotEmpty() && pending.sn == device.sn)
    }

    /// 扫描窗口超时后，将仍未命中的待连接请求按 noDeviceFound 结束。
    private fun expirePendingScanConnects() {
        if (pendingScanConnects.isEmpty()) {
            return
        }
        val now = System.currentTimeMillis()
        val expired = pendingScanConnects.filter { pending ->
            val config = bleConfigs.firstOrNull { it.name == pending.belongConfig } ?: return@filter false
            now - pending.startTimeMs > config.connectTimeout
        }
        for (pending in expired) {
            pendingScanConnects.removeAll { it.uuid.equals(pending.uuid, ignoreCase = true) }
            if (pendingScanConnects.isEmpty()) {
                stopScan()
            }
            connectedDevices.removeAll { it.uuid == pending.uuid && it.myGatt == null }
            handleConnectState(pending.uuid, pending.name, BleConnectState.NO_DEVICE_FOUND)
            sendLog(BleLoggerTag.d, "Start connect: ${pending.uuid}, scan-then-connect timeout")
        }
    }

    /// 扫描命中待连接目标后，带着 isWaitingDevice 继续走 connectGatt。
    private fun tryConnectFromPendingScan(foundDevice: BleDevice) {
        if (pendingScanConnects.isEmpty()) {
            return
        }
        val matched = pendingScanConnects.filter { matchesPendingScan(foundDevice, it) }
        for (pending in matched) {
            pendingScanConnects.removeAll { it.uuid.equals(pending.uuid, ignoreCase = true) }
            if (pendingScanConnects.isEmpty()) {
                stopScan()
            }
            connect(
                pending.belongConfig,
                pending.uuid,
                pending.name,
                pending.sn,
                isWaitingDevice = true,
                afterUpgrade = pending.afterUpgrade,
                directConnect = pending.directConnect,
            )
        }
    }

    /**
     * 创建 Android 扫描回调。
     *
     * 扫描解析、SN 规则、scan response 补 SN、matchCount 聚合和 scan-then-connect 命中都由
     * `BleScanPipeline` 负责；manager 只注入当前缓存和状态机回调。
     */
    private fun createScanCallBack(): ScanCallback =
        BleScanPipeline(
            bleConfigs = {
                // 1. 扫描管线始终读取 manager 当前配置，支持 initConfigs 后立即生效。
                bleConfigs
            },
            scanPureMode = {
                // 2. 纯净扫描是一次扫描会话状态，不进入 pipeline 持久化。
                scanPureMode
            },
            scanResultTemp = scanResultTemp,
            expirePendingScanConnects = {
                // 3. 扫描期间顺手淘汰 scan-then-connect 超时请求，避免 UI 永久 connecting。
                expirePendingScanConnects()
            },
            tryConnectFromPendingScan = { device ->
                // 4. 新扫描结果命中待连接目标后，manager 重新进入 connect 流程。
                tryConnectFromPendingScan(device)
            },
            emitMatchDevices = { sn, devices ->
                // 5. EventChannel 输出保持在 manager，避免 pipeline 关心 Flutter JSON 结构。
                sendMatchDevices(sn, devices)
            },
            sendLog = { tag, message ->
                // 6. 所有扫描日志仍使用 BleManager 统一前缀。
                sendLog(tag, message)
            },
        )

    /**
     *  发送配对设备到Flutter
     */
    private fun sendMatchDevices(sn: String, devices: List<BleDevice>) {
        //  - 4.3、将结果发送到Flutter
        val json = JSONObject()
            .put("sn", sn)
            .put("devices", JSONArray().also { array ->
                devices.forEach { device ->
                    array.put(device.toFlutterJson())
                }
            })
            .toString()
        BleEC.SCAN_RESULT.event?.success(json)
        sendLog(BleLoggerTag.d, "Send match devices: $json)")
    }

    /**
     * 创建单次 GATT session 的 callback。
     *
     * `BleManager` 只负责注入全局状态访问函数；物理链路、服务发现、CCCD、MTU 和 notify
     * 细节全部交给 `BleGattSessionCallback`，避免 manager 再次膨胀成协议栈实现类。
     */
    private fun createConnectCallBack(
        expectedUuid: String,
        source: BleConnectSource,
        afterUpgrade: Boolean = false,
    ): BleGattSessionCallback {
        val admission = registerConnectionAttempt(expectedUuid, source)
        return BleGattSessionCallback(
            expectedUuid = expectedUuid,
            currentDeviceForGatt = { gatt, stage ->
                // 1. callback 需要按 GATT 句柄校验当前 session，避免 stale callback 改写状态。
                if (stage in connectionPipelineStages && currentAdmissionFor(admission) == null) {
                    sendLog(
                        BleLoggerTag.d,
                        "Admission gate: $expectedUuid $stage ignored, stale generation/session",
                    )
                    runCatching { gatt.close() }
                    null
                } else {
                    currentDeviceForGatt(gatt, stage)
                }
            },
            handleConnectState = { uuid, name, state, mtu ->
                // 2. 状态迁移仍集中在 manager，自动回连、队列清理和 EventChannel 都复用一套出口。
                val effectiveAdmission = currentAdmissionFor(admission) ?: admission
                handleConnectState(
                    uuid,
                    name,
                    state,
                    mtu = mtu,
                    source = effectiveAdmission.source,
                    generation = effectiveAdmission.generation,
                )
            },
            onPhysicalConnected = { gatt, device ->
                // 3. 真实 STATE_CONNECTED 只进入 Gate；callback 本身不启动 service discovery。
                onPhysicalConnected(gatt, device, admission, afterUpgrade)
            },
            onSessionTerminal = { gatt, state, mtu ->
                // 4. 终态由 manager 按「释放 Gate -> 清理旧链路 -> 启动 next」顺序原子推进。
                handleTerminalConnectState(gatt, admission, state, mtu)
            },
            isBluetoothEnabled = {
                // 5. 蓝牙关闭时断连由系统监听批量处理，callback 只需要查询当前状态。
                isBluetoothEnabled()
            },
            recoverInsufficientAuthorization = { gatt, device ->
                // 6. 授权失败需要由 manager 统一恢复 cache/bond 状态，callback 不直接操作全局列表。
                recoverInsufficientAuthorization(gatt, device)
            },
            consumeDisconnectingState = { uuid ->
                // 7. 主动断连/超时断连已带有明确状态，消费后不再上报系统断连。
                if (consumeOtaRebootDisconnectSuppression(uuid)) {
                    BleConnectState.DISCONNECT_FROM_SYS
                } else {
                    consumeDisconnectingState(uuid)
                }
            },
            onCharacteristicWriteComplete = { uuid ->
                // 8. 写回调只推进对应 uuid 的发送队列，左右腿并发写不会互相影响。
                val key = reconnectKey(uuid)
                sendCmdQueues[key]?.poll()
                writeNextCommand(uuid)
            },
            emitReceiveData = { map ->
                // 9. EventChannel 必须回到 manager 的协程作用域，避免 callback 持有 Flutter 线程细节。
                mainScope.launch {
                    BleEC.RECEIVE_DATA.event?.success(map)
                }
            },
            sendLog = { tag, message ->
                // 10. 日志仍走 manager 统一出口，保持原有 BleManager:: 前缀和 EventChannel 推送。
                sendLog(tag, message)
            },
        )
    }

    /** 为新 GATT 请求分配 generation/session，并先注册 Gate owner 身份。 */
    @Synchronized
    private fun registerConnectionAttempt(
        endpointId: String,
        source: BleConnectSource,
    ): BleConnectionAdmission {
        val key = reconnectKey(endpointId)
        // 新 session 一旦注册，旧业务 GATT metadata 立即失效；旧 callback 必须同时
        // 匹配 GATT 对象和 admission sessionId，不能误杀新 attempt。
        businessConnectedGattSessions.remove(key)
        val generation = nextConnectionGeneration(connectionAttemptGenerations[key] ?: 0L)
        connectionAttemptGenerations[key] = generation
        val admission = BleConnectionAdmission(
            endpointId = endpointId,
            generation = generation,
            sessionId = connectionSessionSequence.incrementAndGet(),
            source = source,
        )
        connectionAdmissionGate.registerAttempt(endpointId, generation)
        currentAdmissions[key] = admission
        return admission
    }

    /** 返回 exact 当前 admission；source 可被手动点击提升，但三元 identity 必须不变。 */
    private fun currentAdmissionFor(expected: BleConnectionAdmission): BleConnectionAdmission? {
        val current = currentAdmissions[reconnectKey(expected.endpointId)] ?: return null
        return current.takeIf {
            it.generation == expected.generation && it.sessionId == expected.sessionId
        }
    }

    /**
     * 真实物理 callback 到达时发一次 source-tagged contactDevice，并按 callback FIFO 入 Gate。
     */
    @Synchronized
    private fun onPhysicalConnected(
        gatt: BluetoothGatt,
        device: BleDevice,
        expectedAdmission: BleConnectionAdmission,
        afterUpgrade: Boolean,
    ) {
        val admission = currentAdmissionFor(expectedAdmission)
        if (admission == null || device.uuid.isBlank() || device.myGatt !== gatt) {
            sendLog(BleLoggerTag.d, "Admission gate: ${device.uuid}, stale/invalid physical callback ignored")
            runCatching { gatt.close() }
            return
        }
        // pending physical deadline 只覆盖 `connectGatt(true)` 到 STATE_CONNECTED 之间。
        // 必须在进入 Gate 前清除，确保 queued endpoint 不会被 watchdog 关闭。
        autoReconnectSupervisor.onPassivePhysicalConnected(device.uuid, gatt)
        admittedGattSessions[admission.sessionId] = GrantedGattSession(
            admission = admission,
            gatt = gatt,
            device = device,
            afterUpgrade = afterUpgrade,
        )
        when (connectionAdmissionGate.onPhysicalConnected(admission)) {
            BleConnectionAdmissionDecision.GRANTED -> {
                handleConnectState(
                    device.uuid,
                    device.name,
                    BleConnectState.CONTACT_DEVICE,
                    source = admission.source,
                    generation = admission.generation,
                )
                startGrantedGattPipeline(admission)
            }
            BleConnectionAdmissionDecision.QUEUED -> {
                handleConnectState(
                    device.uuid,
                    device.name,
                    BleConnectState.CONTACT_DEVICE,
                    source = admission.source,
                    generation = admission.generation,
                )
                sendLog(BleLoggerTag.d, "Admission gate: ${device.uuid}, queued generation=${admission.generation}")
            }
            BleConnectionAdmissionDecision.DUPLICATE ->
                sendLog(BleLoggerTag.d, "Admission gate: ${device.uuid}, duplicate callback ignored")
            else -> {
                admittedGattSessions.remove(admission.sessionId)
                runCatching { gatt.disconnect() }
                runCatching { gatt.close() }
            }
        }
    }

    /** Gate owner 唯一允许启动 service discovery；此刻才开始计算 connectTimeout。 */
    private fun startGrantedGattPipeline(admission: BleConnectionAdmission) {
        val session = admittedGattSessions[admission.sessionId]
        if (session == null) {
            releaseOrphanedAdmission(admission, "missing GATT session at grant")
            return
        }
        val current = currentAdmissionFor(admission)
        if (current == null) {
            releaseOrphanedAdmission(admission, "missing current admission at grant")
            return
        }
        if (session.device.myGatt !== session.gatt) {
            terminateConnectionAdmission(
                expectedAdmission = current,
                gatt = session.gatt,
                fallbackName = session.device.name,
                state = BleConnectState.SERVICE_FAIL,
            )
            return
        }
        startConnectTimeout(
            session.device.belongConfig,
            session.device.uuid,
            session.device.name,
            session.afterUpgrade,
            admission = current,
        )
        val started = session.gatt.discoverServices()
        if (!started) {
            terminateConnectionAdmission(
                expectedAdmission = current,
                gatt = session.gatt,
                fallbackName = session.device.name,
                state = BleConnectState.SERVICE_FAIL,
            )
            return
        }
        handleConnectState(
            session.device.uuid,
            session.device.name,
            BleConnectState.SEARCH_SERVICE,
            source = current.source,
            generation = current.generation,
        )
    }

    /**
     * 释放 exact owner，并同步启动 Gate 返回的下一条 pipeline。
     *
     * `connectFinish` 不调用本方法；只有业务 deviceConnected、终态或真取消可以释放。
     */
    private fun releaseAdmissionAndStartNext(
        admission: BleConnectionAdmission,
        invalidateEndpoint: Boolean,
    ) {
        releaseConnectionAdmission(admission, invalidateEndpoint)
            ?.let { startGrantedGattPipeline(it) }
    }

    /**
     * 只移除 exact generation/session 并将 Gate 推到下一 owner，不立即运行 next。
     *
     * 终态路径需要先拿到 next，再完成旧 GATT 断连/状态清理，最后才让 next
     * 执行 service discovery，避免旧链路清理与新 pipeline 在 HCI 上叠加。
     */
    private fun releaseConnectionAdmission(
        admission: BleConnectionAdmission,
        invalidateEndpoint: Boolean,
    ): BleConnectionAdmission? {
        val current = currentAdmissionFor(admission) ?: return null
        currentAdmissions.remove(reconnectKey(current.endpointId))
        admittedGattSessions.remove(current.sessionId)
        return if (invalidateEndpoint) {
            connectionAdmissionGate.cancelEndpoint(current.endpointId)
        } else {
            connectionAdmissionGate.complete(
                current.endpointId,
                current.generation,
                current.sessionId,
            )
        }
    }

    /**
     * callback 终态的唯一出口：先释放 exact Gate owner，再复用原状态机清理
     * GATT/定时器并调度长期回连，最后启动其它 endpoint 的 pipeline。
     */
    private fun handleTerminalConnectState(
        gatt: BluetoothGatt,
        expectedAdmission: BleConnectionAdmission,
        state: BleConnectState,
        mtu: Int,
    ) {
        terminateConnectionAdmission(
            expectedAdmission = expectedAdmission,
            gatt = gatt,
            fallbackName = gatt.device.name ?: "",
            state = state,
            mtu = mtu,
        )
    }

    /**
     * 终态时严格按「旧 GATT teardown -> Gate release/next -> 状态事件/长期 retry」执行。
     * Gate 排队期间的迟到 callback 只能终止它自己的 exact session。
     */
    @Synchronized
    private fun terminateConnectionAdmission(
        expectedAdmission: BleConnectionAdmission,
        gatt: BluetoothGatt?,
        fallbackName: String,
        state: BleConnectState,
        mtu: Int = 247,
    ) {
        val current = currentAdmissionFor(expectedAdmission)
        if (current == null) {
            val key = reconnectKey(expectedAdmission.endpointId)
            val completedDevice = connectedDevices.firstOrNull {
                it.uuid.equals(expectedAdmission.endpointId, ignoreCase = true)
            }
            val completedSession = businessConnectedGattSessions[key]
            val exactCompletedSession = completedSession?.let { session ->
                session.gatt === gatt &&
                    session.admission.generation == expectedAdmission.generation &&
                    session.admission.sessionId == expectedAdmission.sessionId
            } == true
            val postAdmissionDisposition = BlePostAdmissionTerminalPolicy.resolve(
                state = state,
                gattAndSessionStillOwnDevice = exactCompletedSession && completedDevice?.myGatt === gatt,
                deviceIsBusinessConnected = completedDevice?.connectState?.isConnected == true,
            )
            if (postAdmissionDisposition == BlePostAdmissionTerminalDisposition.BUSINESS_CONNECTED_SESSION) {
                // deviceConnected 只释放 Gate，不释放 GATT。该 exact GATT 的后续系统断连
                // 仍须完整清理、上报原 attempt source/generation，并让 supervisor 重建
                // passive autoConnect；旧 GATT 因对象身份不匹配只能进入 stale 分支。
                businessConnectedGattSessions.remove(key)
                handleConnectState(
                    expectedAdmission.endpointId,
                    completedDevice?.name ?: fallbackName,
                    state,
                    mtu = mtu,
                    source = expectedAdmission.source,
                    generation = expectedAdmission.generation,
                )
                return
            }
            releaseOrphanedAdmission(expectedAdmission, "stale terminal callback")
            return
        }
        val session = admittedGattSessions[current.sessionId]
        if (gatt != null && session != null && session.gatt !== gatt) {
            sendLog(BleLoggerTag.d, "Admission gate: ${current.endpointId}, stale terminal GATT ignored")
            return
        }
        val device = connectedDevices.firstOrNull {
            it.uuid.equals(current.endpointId, ignoreCase = true)
        }
        if (gatt != null && device?.myGatt !== gatt) {
            sendLog(BleLoggerTag.d, "Admission gate: ${current.endpointId}, terminal callback no longer owns device GATT")
            return
        }

        // 1. 旧句柄先完整释放，避免 next service discovery 与 disconnect/close 叠加。
        device?.releaseAndClear()
        sendCmdQueues.remove(reconnectKey(current.endpointId))

        // 2. Gate 释放后立即启动其它 endpoint。当前 endpoint 的 retry 在后续状态出口调度。
        val next = releaseConnectionAdmission(current, invalidateEndpoint = true)
        next?.let { startGrantedGattPipeline(it) }

        // 3. source 只对当前失败 attempt 有效；supervisor.schedule 会把下一轮复位为 autoReconnect。
        handleConnectState(
            current.endpointId,
            device?.name ?: fallbackName,
            state,
            mtu = mtu,
            source = current.source,
            generation = current.generation,
        )
    }

    /** Gate owner 的 manager context 丢失时也必须释放 exact session，不能静默悬挂 active。 */
    private fun releaseOrphanedAdmission(admission: BleConnectionAdmission, reason: String) {
        currentAdmissionFor(admission)?.let {
            releaseAdmissionAndStartNext(it, invalidateEndpoint = true)
            sendLog(BleLoggerTag.e, "Admission gate: ${admission.endpointId}, released orphan, reason=$reason")
            return
        }
        connectionAdmissionGate.cancelSession(
            admission.endpointId,
            admission.generation,
            admission.sessionId,
        )?.let { startGrantedGattPipeline(it) }
        admittedGattSessions.remove(admission.sessionId)
        sendLog(BleLoggerTag.d, "Admission gate: ${admission.endpointId}, ignored orphan exact session, reason=$reason")
    }

    /** Dart `deviceConnected` 是正常路径唯一 release 点。 */
    @Synchronized
    private fun completeBusinessConnectionAdmission(uuid: String) {
        val key = reconnectKey(uuid)
        currentAdmissions[key]?.let { admission ->
            admittedGattSessions[admission.sessionId]?.let { session ->
                if (session.gatt === session.device.myGatt) {
                    businessConnectedGattSessions[key] = BusinessConnectedGattSession(
                        admission = admission,
                        gatt = session.gatt,
                    )
                }
            }
            releaseAdmissionAndStartNext(admission, invalidateEndpoint = false)
        }
    }

    /** 手动点击提升 pending session 的 source/Gate 优先级，但不新建或取消 GATT。 */
    @Synchronized
    private fun promotePendingAttempt(uuid: String) {
        val key = reconnectKey(uuid)
        val current = currentAdmissions[key] ?: return
        val promoted = current.copy(source = BleConnectSource.MANUAL_RECONNECT)
        currentAdmissions[key] = promoted
        admittedGattSessions[current.sessionId]?.let { session ->
            admittedGattSessions[current.sessionId] = session.copy(admission = promoted)
        }
        connectionAdmissionGate.promote(uuid, current.generation, current.sessionId)
    }

    /** 真取消会失效 generation、移除 active/queued，并立即启动其它 endpoint 的 next owner。 */
    @Synchronized
    private fun cancelConnectionAdmission(uuid: String, reason: String) {
        if (uuid.isBlank()) {
            return
        }
        val key = reconnectKey(uuid)
        currentAdmissions.remove(key)?.let { admittedGattSessions.remove(it.sessionId) }
        connectionAttemptGenerations[key] = nextConnectionGeneration(
            connectionAttemptGenerations[key] ?: 0L,
        )
        connectionAdmissionGate.cancelEndpoint(uuid)?.let { startGrantedGattPipeline(it) }
        sendLog(BleLoggerTag.d, "Admission gate: $uuid cancelled, reason=$reason")
    }

    /**
     * 仅撤销仍未收到物理 callback 的 exact passive GATT。
     *
     * deadline 与 callback 竞争时，已放入 admittedGattSessions 的 GATT 说明它已经进入
     * Gate（可能正在排队），此时必须返回 false 让 supervisor 保留该 session。反之先失效
     * admission/generation 再释放 GATT，迟到 callback 就只能被 stale guard 丢弃。
     */
    @Synchronized
    private fun invalidatePendingPassiveGatt(uuid: String, gatt: BluetoothGatt): Boolean {
        val key = reconnectKey(uuid)
        val device = findConnectedDevice(uuid) ?: return false
        if (device.myGatt !== gatt) {
            return false
        }
        val admission = currentAdmissions[key] ?: return false
        if (admittedGattSessions[admission.sessionId]?.gatt === gatt) {
            return false
        }

        currentAdmissions.remove(key)
        connectionAttemptGenerations[key] = nextConnectionGeneration(
            connectionAttemptGenerations[key] ?: 0L,
        )
        connectionAdmissionGate.cancelEndpoint(uuid)?.let { startGrantedGattPipeline(it) }
        sendCmdQueues.remove(key)
        device.releaseAndClear()
        sendLog(
            BleLoggerTag.d,
            "Admission gate: $uuid, invalidated exact pending passive GATT before physical callback",
        )
        return true
    }

    /**
     * 消费正在主动断连的设备状态。
     *
     * GATT callback 收到断连时需要区分“系统异常断连”和“manager 主动断连”。主动断连状态只
     * 能消费一次，否则后续真正的系统断连会被误判为用户断开。
     */
    private fun consumeDisconnectingState(uuid: String): BleConnectState? {
        // 1. 从列表中找到当前 uuid 的主动断连记录。
        val disconnectingDevice = disconnectingDevices.firstOrNull { it.first == uuid } ?: return null

        // 2. 消费后立即移除，保证该状态不会影响下一轮连接/断连回调。
        disconnectingDevices.remove(disconnectingDevice)
        return disconnectingDevice.second
    }

    /**
     * 移除连接舍比gatt数据
     */
    private fun disconnectDevice(uuid: String, state: BleConnectState, removeBond: Boolean = false) {
        //  1、除了系统断连的状态，其它状态发起断连，都要加入到断连中
        if (state != BleConnectState.DISCONNECT_FROM_SYS) {
            disconnectingDevices.removeAll {
                it.first == uuid
            }
            disconnectingDevices.add(Pair(uuid, state))
        }
        //  2、获取已连接的设备并执行断连
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        //  - 2.1、connectedDevice 本身可能为 null，需要安全调用
        connectedDevice?.let { device ->
            device.releaseAndClear()
            if (removeBond) {
                removeBond(device.uuid)
            }
            sendLog(BleLoggerTag.d, "${device.name} clear all gatt")
        }
        //  3、清空当前设备发送队列，避免断连后继续发送旧指令。
        sendCmdQueues.remove(reconnectKey(uuid))
    }

    /**
     * 发送连接状态到 Flutter。
     */
    private fun sendConnectState(
        uuid: String,
        name: String,
        state: BleConnectState,
        mtu: Int = 247,
        source: BleConnectSource = BleConnectSource.UNKNOWN,
        generation: Long = 0L,
    ) {
        mainScope.launch {
            val json = JSONObject()
                .put("uuid", uuid)
                .put("name", name)
                .put("connectState", state.toFlutterJsonValue())
                .put("mtu", mtu)
                .put("source", source.flutterValue)
                .put("generation", generation)
                .toString()
            BleEC.CONNECT_STATUS.event?.success(json)
        }
    }

    private fun BleDevice.toFlutterJson(): JSONObject = JSONObject()
        .put("belongConfig", belongConfig.name)
        .put("uuid", uuid)
        .put("name", name)
        .put("sn", sn)
        .put("rssi", rssi)
        .put("mac", uuid)
        .put("connectState", connectState.toFlutterJsonValue())

    private fun BleConnectState.toFlutterJsonValue(): String = when (this) {
        BleConnectState.WAITING_CONNECT -> "waitingConnect"
        BleConnectState.CONNECTING -> "connecting"
        BleConnectState.CONTACT_DEVICE -> "contactDevice"
        BleConnectState.SEARCH_SERVICE -> "searchService"
        BleConnectState.SEARCH_CHARS -> "searchChars"
        BleConnectState.START_BINDING -> "startBinding"
        BleConnectState.CONNECT_FINISH -> "connectFinish"
        BleConnectState.DISCONNECT_BY_USER -> "disconnectByUser"
        BleConnectState.DISCONNECT_FROM_SYS -> "disconnectFromSys"
        BleConnectState.EMPTY_UUID -> "emptyUuid"
        BleConnectState.NO_BLE_CONFIG_FOUND -> "noBleConfigFound"
        BleConnectState.NO_DEVICE_FOUND -> "noDeviceFound"
        BleConnectState.ALREADY_BOUND -> "alreadyBound"
        BleConnectState.BOUND_FAIL -> "boundFail"
        BleConnectState.SERVICE_FAIL -> "serviceFail"
        BleConnectState.CHARS_FAIL -> "charsFail"
        BleConnectState.TIMEOUT -> "timeout"
        BleConnectState.BLE_ERROR -> "bleError"
        BleConnectState.SYSTEM_ERROR -> "systemError"
        BleConnectState.CONNECTED -> "connected"
        BleConnectState.UPGRADE -> "upgrade"
        BleConnectState.NONE -> "none"
    }

    /**
     *  处理连接状态
     */
    private fun handleConnectState(
        uuid: String,
        name: String,
        state: BleConnectState,
        removeBond: Boolean = false,
        mtu: Int = 247,
        source: BleConnectSource = currentAdmissions[reconnectKey(uuid)]?.source
            ?: BleConnectSource.UNKNOWN,
        generation: Long = currentAdmissions[reconnectKey(uuid)]?.generation ?: 0L,
        scheduleAutoReconnect: Boolean = true,
    ) {
        //  1、更新连接设备的状态
        connectedDevices.forEach {
            if (it.uuid == uuid) {
                it.connectState = state
                // - 1.1、异常断连/超时标记：下次重连前需先扫描刷新 BLE 协议栈缓存。
                // - 1.2、DISCONNECT_FROM_SYS 表示系统异常断连，协议栈可能丢失设备地址类型元数据。
                // - 1.3、TIMEOUT 表示 connectGatt 静默无反应，同样是协议栈缓存问题的典型表现。
                if (state == BleConnectState.DISCONNECT_FROM_SYS || state == BleConnectState.TIMEOUT) {
                    it.needsScanBeforeConnect = true
                }
            }
        }
        if (state == BleConnectState.DISCONNECT_BY_USER) {
            autoReconnectSupervisor.cancel(uuid, reason = "disconnectByUser state")
        }
        //  2、处理正在连接
        //  注意：CONNECT_FINISH 只表示 BLE 服务/特征流程完成，真正的业务 connected
        //  仍由上层鉴权后调用 deviceConnected 触发，所以这里不取消超时定时器。
        if (state.isFlowConnecting) {
            disconnectingDevices.removeAll {
                it.first == uuid
            }
        }
        //  3、处理断连和错误连接
        else if (state.isDisconnected || state.isError) {
            disconnectDevice(uuid, state, removeBond)
        }
        //  4、处理连接成功（uuid 用 ignoreCase 比较：connect 与 setConnected 可能来自不同链路，MAC 大小写不一致会导致匹配不到，定时器无法清除）
        else if (state.isConnected) {
            // - 4.1、连接成功后清理当前设备上的超时定时器。
            connectedDevices.firstOrNull {
                it.uuid.equals(uuid, ignoreCase = true)
            }?.let {
                it.timeoutTimer?.cancel()
                it.timeoutTimer = null
                if (state == BleConnectState.CONNECTED) {
                    autoReconnectSupervisor.arm(it)
                }
            }
            // - 4.2、从断连中设备列表中移除当前设备。
            disconnectingDevices.removeAll {
                it.first == uuid
            }
        }
        //  5、发送连接状态
        sendConnectState(uuid, name, state, mtu, source, generation)
        if (scheduleAutoReconnect && (state.isDisconnected || state.isError)) {
            autoReconnectSupervisor.schedule(uuid, state)
        }
    }

    /**
     * 清除GATT缓存信息（利用反射读取gatt中的"refresh"）
	 * Clears the internal cache and forces a refresh of the services from the
	 * remote device.
	 */
    private fun refreshDeviceCache(gatt: BluetoothGatt?): Boolean {
        gatt?.let {
            try {
                val localMethod = it.javaClass.getMethod("refresh")
                if (localMethod != null) {
                    val refresh = localMethod.invoke(it) as Boolean
                    sendLog(BleLoggerTag.d, "${gatt.device.address}-${gatt
                        .device.name} refresh gatt device cache success = $refresh")
                    return refresh
                }
            } catch (localException: Exception) {
                sendLog(BleLoggerTag.e, "${gatt.device.address}-${gatt
                    .device.name} refresh gatt device cache error: ${localException.message}")
            }
        }
        return false
    }

    /**
     * 恢复 Android 返回 GATT_INSUFFICIENT_AUTHORIZATION 后的授权状态。
     *
     * status=8 只能说明当前 GATT session 被系统拒绝访问，不能等价为系统配对已损坏。
     * 自动重连场景必须保留用户的系统 bond，否则 G2/R1 会反复弹系统配对框。清 bond 只允许走
     * 用户明确移除设备时传入的 removeBond=true 路径。
     */
    private fun recoverInsufficientAuthorization(gatt: BluetoothGatt, device: BleDevice) {
        val refreshed = refreshDeviceCache(gatt)
        device.needsScanBeforeConnect = true
        val bondState = gatt.device.bondState
        sendLog(
            BleLoggerTag.d,
            "${device.uuid}, authorization recovery: refresh=$refreshed, bond=${bondState.toBondStateName()}, keepBond=true",
        )
    }

    /**
     * 仅用于授权恢复日志，避免后续排障还要人工记 Android bondState 数字。
     */
    private fun Int.toBondStateName(): String = when (this) {
        BluetoothDevice.BOND_NONE -> "BOND_NONE"
        BluetoothDevice.BOND_BONDING -> "BOND_BONDING"
        BluetoothDevice.BOND_BONDED -> "BOND_BONDED"
        else -> "UNKNOWN($this)"
    }

    /**
     *  移除配对
     */
    private fun removeBond(address: String) {
        val device: BluetoothDevice = bluetoothAdapter.getRemoteDevice(address)
        try {
            val method = device.javaClass.getMethod("removeBond")
            val result = method.invoke(device) as Boolean
            sendLog(BleLoggerTag.d, "$address, remove bond result: $result")
        } catch (e: Exception) {
            sendLog(BleLoggerTag.e, "$address, remove bond error: ${e.message}")
        }
    }

    /**
     *  处理日志
     */
    private fun sendLog(tag: BleLoggerTag, log: String) {
        val message = "${tag.tag}BleManager::$log"
        if (tag == BleLoggerTag.e) {
            Log.e(logcatTag, message)
        } else {
            Log.d(logcatTag, message)
        }
        if (!this::mainScope.isInitialized || !mainScope.isActive) return
        mainScope.launch {
            BleEC.LOGGER.event?.success(message)
        }
    }
}
