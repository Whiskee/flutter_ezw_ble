package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import android.os.SystemClock
import com.fzfstudio.ezw_ble.ble.models.BleCmd
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BluetoothGattStatus
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import java.util.LinkedList
import java.util.Queue
import java.util.Timer
import java.util.TimerTask

/**
 * 一条 Android GATT session 的完整回调处理器。
 *
 * 该类把 `BluetoothGattCallback` 从 `BleManager` 中拆出：它只处理物理链路、服务发现、
 * CCCD 写入、MTU、notify 和写入回调。设备缓存、状态机、日志和 EventChannel 输出仍通过
 * 注入的函数回到 `BleManager`，避免 callback 直接拥有全局状态。
 */
internal class BleGattSessionCallback(
    /** 本次 GATT session 期望归属的设备 UUID/address；用于过滤 Android autoConnect 串来的非目标回调。 */
    private val expectedUuid: String?,
    /** 根据回调中的 GATT 句柄解析当前 session 对应的设备，并过滤 stale GATT。 */
    private val currentDeviceForGatt: (BluetoothGatt, String) -> BleDevice?,
    /** 将连接阶段推进给 manager，由 manager 统一更新状态和 EventChannel。 */
    private val handleConnectState: (String, String, BleConnectState, Int) -> Unit,
    /** 记录当前 native attempt 的阶段；Trace 关闭时 manager 会直接 no-op。 */
    private val recordTraceStep: (String, String, String, String?, String?, Int?) -> Unit,
    /** MTU 回调附带 ATT 可写载荷上限，避免把协商 MTU 与业务 payload 混为一谈。 */
    private val recordTraceMtu: (String, String, Int, Int) -> Unit,
    /** 写入最新 RSSI 诊断快照，不独立上报。 */
    private val updateTraceRssi: (String, Int) -> Unit,
    /** 写入 controller 实际 PHY 诊断快照。 */
    private val updateTracePhy: (String, String?) -> Unit,
    /** 写入最近一次 Android requested connection priority。 */
    private val updateTraceRequestedPriority: (String, String?, Boolean) -> Unit,
    /** 记录 PHY 策略请求、回退和失败；真实 PHY 仍只认 onPhyUpdate。 */
    private val recordTracePhyPolicy: (String, String, String, String) -> Unit,
    /** 真实物理连接只提交给全局 Gate；Gate owner 才能开始 service discovery。 */
    private val onPhysicalConnected: (BluetoothGatt, BleDevice) -> Unit,
    /** 当前 session 进入终态时，由 manager 先释放 Gate、再清理状态并启动下一条 pipeline。 */
    private val onSessionTerminal: (BluetoothGatt, BleConnectState, Int) -> Unit,
    /** 查询系统蓝牙是否仍可用；蓝牙关闭时断连由系统状态监听统一处理。 */
    private val isBluetoothEnabled: () -> Boolean,
    /** 处理 ATT/GATT 操作返回授权不足；连接状态回调不得调用这个恢复入口。 */
    private val recoverInsufficientAuthorization: (BluetoothGatt, BleDevice) -> Unit,
    /** 5403 写优先由 exact registry 认领，不能进入普通命令或 OTA 写队列。 */
    private val securityGateAttempts: BleAndroidSecurityGateAttemptRegistry,
    /** 用 admission/session/GATT 对象构造本 callback 唯一 Gate owner。 */
    private val securityGateOwner: (BluetoothGatt) -> BleAndroidSecurityGateOwner,
    /** 由 endpoint 恢复 episode 把安全失败映射为重试、耗尽或手动失败。 */
    private val onSecurityGateFailure:
        (BluetoothGatt, BleDevice, String, Int) -> BleAndroidSecurityRecoveryAction,
    /** Gate 成功后清除 endpoint 的安全失败预算。 */
    private val onSecurityGatePassed: (String) -> Unit,
    /**
     * Android 旧固件缺少可写 5403 时，把主动 Bond 交回持有 exact admission 的 manager。
     * 返回 true 表示普通 Notify 必须暂停，等待同一 GATT 完成 Bond 后重新发现服务。
     */
    private val onSecurityGateUnavailable: (BluetoothGatt, BleDevice) -> Boolean,
    /** 查询一个 uuid 是否正处于 manager 主动断连流程。 */
    private val consumeDisconnectingState: (String) -> BleConnectState?,
    /** 通知 manager 写入完成，并携带 psType/status 让普通队列与 OTA 背压队列精确认领。 */
    private val onCharacteristicWriteComplete: (String, Int?, Int, String) -> Unit,
    /** 把 notify 数据回传到 Flutter EventChannel。 */
    private val emitReceiveData: (Map<String, Any?>) -> Unit,
    /** 统一日志出口，保证所有 GATT 日志仍带 BleManager 前缀。 */
    private val sendLog: (BleLoggerTag, String) -> Unit,
) : BluetoothGattCallback() {

    /** 私有服务是否已全部解析完成；未完成时 descriptor/MTU 回调不应推进连接完成。 */
    private var isPrivateServiceReady = false

    /** CCCD 写入队列必须跟随单个 callback，避免多设备并发连接时互相消费 descriptor。 */
    private val descriptorQueue: Queue<Pair<Int, BluetoothGattDescriptor>> = LinkedList()

    /** 当前已提交、正在等待 onDescriptorWrite 的 CCCD 所属私有服务类型。 */
    private var inFlightDescriptorPsType: Int? = null

    /** 高可靠配置的单 session RSSI/空闲优先级监测器；终态必须跟随 callback 一起失效。 */
    private var adaptiveLinkTimer: Timer? = null

    /** 避免上一次 RSSI callback 未返回时重复提交读取。 */
    @Volatile
    private var isRssiReadPending = false

    /** 最近一次成功 RSSI，用于 supervision timeout 日志还原物理劣化前的链路质量。 */
    @Volatile
    private var lastRssi: Int? = null

    /** 当前请求的 PHY；RSSI 迟滞区保持此值，避免强弱边缘反复切换。 */
    @Volatile
    private var requestedPhy = BluetoothDevice.PHY_LE_1M

    /** controller 实际回调的收发 PHY，仅用于诊断，不参与 owner 判定。 */
    @Volatile
    private var activeTxPhy: Int? = null

    @Volatile
    private var activeRxPhy: Int? = null

    /** 最后一次真实 notify/write 活动；用它在 high 与 balanced priority 之间收敛。 */
    @Volatile
    private var lastLinkActivityAtMs = 0L

    /** 避免每个高频音频包都重复 requestConnectionPriority。 */
    @Volatile
    private var isHighConnectionPriority = false

    /**
     * 监听物理链路连接/断开。
     *
     * Android 会把主动断开、系统断连、蓝牙关闭、授权失败都汇聚到这里，因此必须先区分
     * 是否仍属于当前 GATT session，再决定由连接流程还是蓝牙状态监听处理。
     */
    @Synchronized
    override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        // 1. 新的物理连接状态到来后，旧 descriptor 队列都不再可信。
        val address = gatt.device.address
        descriptorQueue.clear()
        inFlightDescriptorPsType = null

        // 2. 物理链路建立后只提交全局 Gate。禁止在 callback 内直接 discoverServices，
        //    否则多设备会同时占用 HCI/GATT 初始化通道。
        if (newState == BluetoothProfile.STATE_CONNECTED) {
            val connectedDevice = currentExpectedDeviceForGatt(gatt, "connection connected") ?: return
            recordTraceStep(address, "connect", "success", null, "HCI", status)
            startAdaptiveLinkMonitoring(gatt, connectedDevice)
            onPhysicalConnected(gatt, connectedDevice)
            sendLog(
                BleLoggerTag.d,
                "Connect call back: $address had contact device, state = STATE_CONNECTED(code:2), wait global admission gate",
            )
            return
        }

        // 3. 只处理断连状态，连接中/其它状态不改变当前状态机。
        if (newState != BluetoothProfile.STATE_DISCONNECTED) {
            return
        }

        // 4. 物理断连后任何 RSSI/PHY/priority 请求都必须停止，不能让旧 callback 持有新 session。
        stopAdaptiveLinkMonitoring()

        // 5. 蓝牙关闭时不在这里释放，避免和 BleStateListener 对同一批设备重复断连。
        if (!isBluetoothEnabled()) {
            sendLog(
                BleLoggerTag.e,
                "Connect call back: $address, not handle disconnect form state change, will call disconnect method in the ble state Listener",
            )
            return
        }

        // 6. 断连会使本 session 的 GATT readiness 失效。
        isPrivateServiceReady = false
        val device = currentExpectedDeviceForGatt(gatt, "connection disconnected") ?: return
        val connectionStatus = BluetoothGattStatus.getConnectionStatusDescription(status)

        // 7. 连接状态回调中的 status 是 HCI/controller 断连原因，不是 ATT/GATT 操作码。
        //    例如 status 8 在这里表示连接超时；只有 descriptor/characteristic 回调里的 8
        //    才能按 GATT_INSUFFICIENT_AUTHORIZATION 解释和记录。

        // 8. Gate 写在途时，HCI Authentication Failure/Key Missing 属于安全失败。
        val gateOwner = securityGateOwner(gatt)
        if (securityGateAttempts.isInFlight(gateOwner) &&
            BleAndroidSecurityFailureClassifier.isHciSecurityFailure(status)
        ) {
            securityGateAttempts.consumeInFlight(gateOwner)
            val action = onSecurityGateFailure(gatt, device, "HCI", status)
            recordTraceStep(address, "security_gate", "failed", null, "HCI", status)
            terminateSession(gatt, action.toTerminalState(), DEFAULT_MTU)
            return
        }

        // 9. 当前 active GATT 在 connecting 阶段收到断连，说明本轮 connectGatt 已经失败。
        //    不能继续静默 keep connecting：G2 第二条腿会等满 timeout，甚至在部分机型上丢失终态。
        //    stale GATT 已在 currentExpectedDeviceForGatt 里过滤，这里可以安全落本轮 timeout。
        if (device.connectState.isConnecting) {
            sendLog(
                BleLoggerTag.e,
                "Connect call back: $address disconnected while connecting, fail active connect as timeout, code=$connectionStatus, lastRssi=$lastRssi, txPhy=${phyLabel(activeTxPhy)}, rxPhy=${phyLabel(activeRxPhy)}",
            )
            recordTraceStep(address, "connect", "failed", null, "HCI", status)
            terminateSession(gatt, BleConnectState.TIMEOUT, DEFAULT_MTU)
            return
        }

        // 9. 释放 native GATT 资源；不 close 会让后续连接占住旧 binder session。
        try {
            gatt.close()
        } catch (closeError: Exception) {
            sendLog(BleLoggerTag.e, "Connect call back: $address close gatt exception: ${closeError.message}")
        }

        // 10. 用户/超时主动断连已经有明确状态，不再二次上报系统断连。
        val explicitDisconnectState = consumeDisconnectingState(device.uuid)
        if (explicitDisconnectState != null) {
            sendLog(
                BleLoggerTag.e,
                "Connect call back: $address is disconnecting witch state = $explicitDisconnectState, stop disconnect flow form system",
            )
            return
        }

        // 11. 非主动断连统一上报系统断连，由 manager 决定是否调度自动回连。
        sendLog(
            BleLoggerTag.e,
            "Connect call back: $address state = STATE_DISCONNECTED(code:$connectionStatus), lastRssi=$lastRssi, txPhy=${phyLabel(activeTxPhy)}, rxPhy=${phyLabel(activeRxPhy)}",
        )
        recordTraceStep(address, "disconnect", "abnormal", null, "HCI", status)
        terminateSession(gatt, BleConnectState.DISCONNECT_FROM_SYS, DEFAULT_MTU)
    }

    /**
     * 处理服务发现结果并建立私有服务读写通道。
     *
     * 每次物理回连后都必须重新发现 service、characteristic 并写 CCCD；autoConnect 只恢复物理链路，
     * 不会帮业务恢复私有服务和 notify。
     */
    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        // 1. 回调必须属于当前 session，否则不能污染当前设备的 characteristic 缓存。
        val address = gatt.device.address
        val currentDevice = currentExpectedDeviceForGatt(gatt, "services discovered") ?: return
        val name = currentDevice.name

        // 2. 服务发现失败直接进入 SERVICE_FAIL，等待上层或自动回连策略处理。
        if (status != BluetoothGatt.GATT_SUCCESS) {
            recordTraceStep(address, "service_discovery", "failed", null, "GATT", status)
            terminateSession(gatt, BleConnectState.SERVICE_FAIL, DEFAULT_MTU)
            sendLog(BleLoggerTag.e, "Connect call back: $address, discover service failure")
            return
        }

        recordTraceStep(address, "service_discovery", "success", null, "GATT", status)

        // 3. 可选 5403 必须先以 Write Request 验证系统 Bond。Android G2 的正常顺序
        // 已由 admission 先完成主动 Bond；这里的缺失 Gate 回调仅保留给旧固件和旧配置兜底。
        val securityGate = currentDevice.belongConfig.securityGate
        if (securityGate != null) {
            val gateCharacteristic = runCatching {
                gatt.getService(securityGate.serviceUUID)
                    ?.getCharacteristic(securityGate.writeCharsUUID)
            }.getOrNull()
            val supportsWriteRequest = gateCharacteristic?.let { characteristic ->
                characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
            } == true
            if (supportsWriteRequest) {
                startSecurityGateWrite(gatt, currentDevice, gateCharacteristic)
                return
            }
            recordTraceStep(address, "security_gate", "not_observable", null, null, null)
            sendLog(
                BleLoggerTag.d,
                "Security gate: $address missing or unsupported, evaluate legacy system bond",
            )
            if (onSecurityGateUnavailable(gatt, currentDevice)) {
                return
            }
        }

        // 4. 没有可执行 Gate 时进入普通 GATT 初始化。
        startPrivateGattReadiness(gatt, currentDevice)
    }

    /** Gate 成功或兼容路径唯一允许进入的普通服务/Notify 初始化入口。 */
    private fun startPrivateGattReadiness(gatt: BluetoothGatt, currentDevice: BleDevice) {
        val address = gatt.device.address
        isPrivateServiceReady = true
        currentDevice.belongConfig.privateServices.forEach { privateService ->
            val service = gatt.getService(privateService.serviceUUID)
            val writeChars = service?.getCharacteristic(privateService.writeCharsUUID)
            if (writeChars == null) {
                recordTraceStep(address, "characteristic_discovery", "failed", privateService.type.toString(), null, null)
                sendLog(BleLoggerTag.e, "Connect call back: $address, ${privateService.service}, write characteristic not found")
                terminateSession(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
                isPrivateServiceReady = false
                return
            }

            val readChars = service.getCharacteristic(privateService.readCharsUUID)
            if (readChars == null) {
                recordTraceStep(address, "characteristic_discovery", "failed", privateService.type.toString(), null, null)
                sendLog(BleLoggerTag.e, "Connect call back: $address, ${privateService.service}, read characteristic not found")
                terminateSession(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
                isPrivateServiceReady = false
                return
            }

            // 4. 先打开 characteristic notification，再按队列写 CCCD，保证所有私有服务都 ready。
            val notifySuccess = gatt.setCharacteristicNotification(readChars, true)
            sendLog(BleLoggerTag.d, "Connect call back: $address, ${privateService.service}, set chars notify success = $notifySuccess")
            descriptorQueue.add(Pair(privateService.type, readChars.getDescriptor(BleManager.cccdDescriptor)))

            // 5. 缓存当前 session 的读写 characteristic；断连时 BleDevice 会清空这些缓存。
            currentDevice.update(gatt, privateService.type, writeChars, readChars)
        }
        recordTraceStep(address, "characteristic_discovery", "success", null, null, null)

        // 6. 如果任一私有服务失败，等待失败状态处理，不再继续写 descriptor。
        if (!isPrivateServiceReady) {
            return
        }

        // 7. 所有 service/characteristic 都存在后，开始串行写 CCCD。
        processNextDescriptor(gatt)
    }

    /** 同一 exact attempt 只提交一次 5403 有响应写。 */
    private fun startSecurityGateWrite(
        gatt: BluetoothGatt,
        device: BleDevice,
        characteristic: BluetoothGattCharacteristic,
    ) {
        val owner = securityGateOwner(gatt)
        if (!securityGateAttempts.start(owner, characteristic.uuid)) {
            sendLog(
                BleLoggerTag.d,
                "Security gate: ${device.uuid} duplicate service callback ignored, " +
                    "passed=${securityGateAttempts.hasPassed(owner)}",
            )
            return
        }
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        recordTraceStep(device.uuid, "security_gate", "started", null, null, null)
        val accepted = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    byteArrayOf(0),
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = byteArrayOf(0)
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
        }.getOrDefault(false)
        if (!accepted) {
            // 同步 BUSY/拒绝不是密钥证据，不消耗安全恢复预算。
            securityGateAttempts.cancel(owner)
            recordTraceStep(device.uuid, "security_gate", "failed", null, null, null)
            terminateSession(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
            return
        }
        sendLog(BleLoggerTag.d, "Security gate: ${device.uuid} protected write submitted")
    }

    /**
     * 处理单个 CCCD 写入完成。
     *
     * Android 的 descriptor 写入必须串行；上一个 callback 到来后才可以写下一个 descriptor。
     */
    override fun onDescriptorWrite(
        gatt: BluetoothGatt?,
        descriptor: BluetoothGattDescriptor?,
        status: Int,
    ) {
        super.onDescriptorWrite(gatt, descriptor, status)

        // 1. 私有服务未 ready 时，descriptor 回调可能来自 stale session，直接忽略。
        if (!isPrivateServiceReady) {
            return
        }

        // 2. 空 GATT 或 stale GATT 都不能继续推进队列。
        val device = if (gatt == null) {
            null
        } else {
            currentExpectedDeviceForGatt(gatt, "descriptor write")
        }
        if (gatt == null || device == null) {
            return
        }

        // 3. CCCD 写入失败时必须终止本次 GATT readiness；否则 Dart 侧会一直等
        // connectFinish，而 auto reconnect supervisor 也拿不到可重试的失败终态。
        if (status != BluetoothGatt.GATT_SUCCESS) {
            // 失败明细必须在清空队列 owner 前冻结，否则 service_type 永远丢失。
            val failedDescriptorPsType = inFlightDescriptorPsType
            descriptorQueue.clear()
            inFlightDescriptorPsType = null
            isPrivateServiceReady = false
            val operationStatus = BluetoothGattStatus.getGattOperationStatusDescription(status)
            recordTraceStep(
                gatt.device.address,
                "cccd",
                "failed",
                failedDescriptorPsType?.toString(),
                "GATT",
                status,
            )
            if (status == BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION) {
                // Descriptor write 已进入 GATT readiness 阶段；这里的 8 是 ATT/GATT 授权不足，
                // 先恢复 cache/bond 视图，再按原失败语义终止为 CHARS_FAIL 触发重试。
                recoverInsufficientAuthorization(gatt, device)
            }
            sendLog(
                BleLoggerTag.e,
                "Connect call back: ${gatt.device.address} descriptor write failed, status=$operationStatus",
            )
            terminateSession(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
            return
        }

        // 4. 当前 descriptor 已完成，继续写下一个；队列空时会请求 MTU。
        inFlightDescriptorPsType?.let { device.markNotifyReady(it) }
        recordTraceStep(gatt.device.address, "cccd", "success", inFlightDescriptorPsType?.toString(), "GATT", status)
        inFlightDescriptorPsType = null
        sendLog(BleLoggerTag.d, "Connect call back: ${gatt.device.address} is descriptor write success = ${status == BluetoothGatt.GATT_SUCCESS}")
        processNextDescriptor(gatt)
    }

    /**
     * 处理旧版 characteristic notify 回调。
     *
     * 这里保留旧签名是为了兼容当前插件支持的 Android 版本；新版带 value 参数的回调暂不启用。
     */
    override fun onCharacteristicChanged(
        gatt: BluetoothGatt?,
        characteristic: BluetoothGattCharacteristic?,
    ) {
        super.onCharacteristicChanged(gatt, characteristic)

        // 1. notify 数据必须同时具备 GATT 和 characteristic。
        if (gatt == null || characteristic == null) {
            sendLog(BleLoggerTag.e, "Receive cmd: ${gatt?.device?.address} receive fail, gatt or characteristic is null")
            return
        }

        // 2. stale GATT 不能回传数据，避免旧 session 的 notify 污染新连接。
        val connectedDevice = currentExpectedDeviceForGatt(gatt, "characteristic changed") ?: return
        noteLinkActivity(gatt, connectedDevice)

        // 3. 根据 read characteristic UUID 反查私有服务类型，保持 Dart 收包 psType 正确。
        val privateService = connectedDevice.belongConfig.privateServices.firstOrNull { service ->
            service.readCharsUUID == characteristic.uuid
        }
        if (privateService == null) {
            sendLog(BleLoggerTag.e, "Receive cmd: ${gatt.device.address} receive fail, not found current uuid")
            return
        }

        // 4. 数据回传仍走 Base64 Map，由 BleCmd 统一编码。
        val bleCmdMap = BleCmd(gatt.device.address, privateService.type, characteristic.value, true).toFlutterMap()
        emitReceiveData(bleCmdMap)
        sendLog(
            BleLoggerTag.d,
            "Receive cmd(old): ${gatt.device.address}, type=${privateService.type}, length=${characteristic.value.size}, chartsType=${characteristic.writeType}",
        )
    }

    /**
     * 处理 characteristic 写入完成。
     *
     * 写入队列由 manager 维护；callback 只通知“当前写完成”，再让 manager 发送下一条。
     */
    override fun onCharacteristicWrite(
        gatt: BluetoothGatt?,
        characteristic: BluetoothGattCharacteristic?,
        status: Int,
    ) {
        super.onCharacteristicWrite(gatt, characteristic, status)

        // 1. 没有 GATT 无法定位设备，直接忽略。
        val address = gatt?.device?.address ?: return

        // 2. stale GATT 的写回调不能消费当前队列。
        val device = currentExpectedDeviceForGatt(gatt, "characteristic write")
        if (device == null) {
            return
        }
        noteLinkActivity(gatt, device)

        // 3. Gate registry 优先认领 5403；它绝不能 poll 普通命令或 OTA 队列。
        val gateOwner = securityGateOwner(gatt)
        if (characteristic != null &&
            securityGateAttempts.consume(gateOwner, characteristic.uuid) != null
        ) {
            val operationStatus = BluetoothGattStatus.getGattOperationStatusDescription(status)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                securityGateAttempts.markPassed(gateOwner)
                onSecurityGatePassed(device.uuid)
                recordTraceStep(address, "security_gate", "success", null, "GATT", status)
                sendLog(BleLoggerTag.d, "Security gate: $address write success, begin Notify readiness")
                startPrivateGattReadiness(gatt, device)
                return
            }
            if (BleAndroidSecurityFailureClassifier.isGattSecurityFailure(status)) {
                recoverInsufficientAuthorization(gatt, device)
                val action = onSecurityGateFailure(gatt, device, "GATT", status)
                recordTraceStep(address, "security_gate", "failed", null, "GATT", status)
                sendLog(
                    BleLoggerTag.e,
                    "Security gate: $address write failed, status=$operationStatus, action=$action",
                )
                terminateSession(gatt, action.toTerminalState(), DEFAULT_MTU)
                return
            }
            recordTraceStep(address, "security_gate", "failed", null, "GATT", status)
            sendLog(
                BleLoggerTag.e,
                "Security gate: $address non-security write failure, status=$operationStatus",
            )
            terminateSession(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
            return
        }

        // 4. 业务 connected 后写 characteristic 返回授权不足，说明系统 GATT/bond 视图已拒绝。
        //    先恢复本端缓存，再以系统断连终止本 session；不能继续 poll/writeNext 消费发送队列。
        val operationStatus = BluetoothGattStatus.getGattOperationStatusDescription(status)
        if (status == BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION) {
            recoverInsufficientAuthorization(gatt, device)
            sendLog(BleLoggerTag.e, "Send cmd: $address, write failed, status=$operationStatus, terminal=DISCONNECT_FROM_SYS")
            terminateSession(gatt, BleConnectState.DISCONNECT_FROM_SYS, DEFAULT_MTU)
            return
        }

        // 5. 其余 characteristic write 状态交给 manager 精确匹配普通/OTA owner；OTA Future
        //    只有在这里成功后才完成，不能再把同步提交成功当成 GATT 单槽位已经释放。
        sendLog(BleLoggerTag.d, "Send cmd: $address, write call back is success = ${status == BluetoothGatt.GATT_SUCCESS}, status=$operationStatus")
        onCharacteristicWriteComplete(
            address,
            device.psTypeForWriteCharacteristic(characteristic),
            status,
            operationStatus,
        )
    }

    /**
     * MTU 请求完成后结束 GATT readiness。
     *
     * 即使 MTU 修改失败，当前私有服务和 notify 已 ready，仍按旧行为推进 connectFinish。
     */
    override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
        super.onMtuChanged(gatt, mtu, status)

        // 1. 只有私有服务与 descriptor 全部完成后，MTU 才能作为连接完成信号。
        if (!isPrivateServiceReady) {
            return
        }

        // 2. stale GATT 的 MTU 回调不能推进当前连接。
        if (gatt == null || currentExpectedDeviceForGatt(gatt, "mtu changed") == null) {
            return
        }

        // 3. 保留旧行为：MTU 成功/失败都进入连接完成判断。
        recordTraceMtu(
            gatt.device.address,
            if (status == BluetoothGatt.GATT_SUCCESS) "success" else "failed",
            (mtu - 3).coerceAtLeast(0),
            status,
        )
        sendLog(
            BleLoggerTag.d,
            "Connect call back: ${gatt.device.address} change mtu ${if (status == BluetoothGatt.GATT_SUCCESS) "success" else "failed"}, new mtu value = $mtu, connecting flow is finish",
        )
        connectingFlowFinish(gatt, mtu)
    }

    /**
     * PHY 读回只用于确认当前链路是 1M 还是 2M，不得影响连接状态机。
     */
    override fun onPhyRead(gatt: BluetoothGatt?, txPhy: Int, rxPhy: Int, status: Int) {
        super.onPhyRead(gatt, txPhy, rxPhy, status)
        val address = gatt?.device?.address ?: return
        sendLog(
            BleLoggerTag.d,
            "[ezw_ble][phy] read endpoint=$address tx=${BleAndroidPreferredPhy.describe(txPhy)} " +
                "rx=${BleAndroidPreferredPhy.describe(rxPhy)} status=$status",
        )
    }

    /**
     * `setPreferredPhy` 的异步结果。失败或仍停在 1M 只记日志，不能回退 connectFinish。
     */
    override fun onPhyUpdate(gatt: BluetoothGatt?, txPhy: Int, rxPhy: Int, status: Int) {
        super.onPhyUpdate(gatt, txPhy, rxPhy, status)
        val address = gatt?.device?.address ?: return
        sendLog(
            BleLoggerTag.d,
            "[ezw_ble][phy] update endpoint=$address tx=${BleAndroidPreferredPhy.describe(txPhy)} " +
                "rx=${BleAndroidPreferredPhy.describe(rxPhy)} status=$status",
        )
    }

    /**
     * 串行写入下一个 CCCD。
     *
     * Android descriptor 写入是异步操作，不能在循环里一次性写完；否则后写入会覆盖前写入。
     */
    private fun processNextDescriptor(gatt: BluetoothGatt?) {
        // 1. GATT 已经释放时清空队列，避免旧 descriptor 后续继续执行。
        if (gatt == null) {
            descriptorQueue.clear()
            return
        }

        // 2. 队列空说明所有 notify 都启用，下一步请求 MTU。
        if (descriptorQueue.isEmpty()) {
            requestDeviceMtu(gatt)
            return
        }

        // 3. 写入队首 descriptor，等待 onDescriptorWrite 回调再继续。
        val item = descriptorQueue.poll() ?: return
        val descriptor = item.second
        inFlightDescriptorPsType = item.first
        val isWrite = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
        } else {
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            gatt.writeDescriptor(descriptor)
        }
        sendLog(
            BleLoggerTag.d,
            "Connect call back: ${gatt.device.address} desUuid = ${descriptor.uuid}, chars = ${descriptor.characteristic.uuid}, psType=${item.first}, enable descriptor and write = $isWrite",
        )
        // 4. writeDescriptor 返回 false/非 SUCCESS 时不会再有 onDescriptorWrite 回调；
        // 这里必须主动给出终态，避免连接流程卡在 connecting。
        if (!isWrite) {
            val device = currentExpectedDeviceForGatt(gatt, "descriptor enqueue failure") ?: return
            descriptorQueue.clear()
            inFlightDescriptorPsType = null
            isPrivateServiceReady = false
            sendLog(
                BleLoggerTag.e,
                "Connect call back: ${gatt.device.address} descriptor write request rejected, psType=${item.first}",
            )
            recordTraceStep(gatt.device.address, "cccd", "failed", item.first.toString(), null, null)
            terminateSession(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
        }
    }

    /**
     * 消费 RSSI 采样并驱动带迟滞的 PHY 选择。
     *
     * RSSI 只影响高可靠配置的链路偏好，不参与 GATT ready/业务 connected 判定；读取失败只记
     * 诊断日志，不能制造连接终态。
     */
    override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
        super.onReadRemoteRssi(gatt, rssi, status)
        isRssiReadPending = false
        val device = currentExpectedDeviceForGatt(gatt, "remote RSSI") ?: return
        if (!device.belongConfig.androidHighReliabilityMode) {
            return
        }
        if (status != BluetoothGatt.GATT_SUCCESS) {
            sendLog(
                BleLoggerTag.e,
                "Link quality: ${device.uuid}, RSSI read failed, status=${BluetoothGattStatus.getGattOperationStatusDescription(status)}",
            )
            return
        }

        device.rssi = rssi
        lastRssi = rssi
        updateTraceRssi(device.uuid, rssi)
        val targetPhy = AndroidBleAdaptiveLinkPolicy.preferredPhy(requestedPhy, rssi)
        val isWeak = rssi <= AndroidBleAdaptiveLinkPolicy.FALLBACK_TO_1M_RSSI_DBM
        sendLog(
            if (isWeak) BleLoggerTag.e else BleLoggerTag.d,
            "Link quality: ${device.uuid}, rssi=${rssi}dBm, requestedPhy=${phyLabel(requestedPhy)}, targetPhy=${phyLabel(targetPhy)}, weak=$isWeak",
        )
        requestPreferredPhy(gatt, targetPhy)
    }

    /** 记录 controller 最终采用的 PHY；setPreferredPhy 只是偏好，真实结果以该回调为准。 */
    override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
        super.onPhyUpdate(gatt, txPhy, rxPhy, status)
        val device = currentExpectedDeviceForGatt(gatt, "PHY update") ?: return
        if (!device.belongConfig.androidHighReliabilityMode) {
            return
        }
        if (status == BluetoothGatt.GATT_SUCCESS) {
            activeTxPhy = txPhy
            activeRxPhy = rxPhy
            updateTracePhy(device.uuid, phyLabel(txPhy))
        } else {
            recordTracePhyPolicy(
                device.uuid,
                "phy_update_failed",
                phyLabel(requestedPhy),
                "failed",
            )
        }
        sendLog(
            if (status == BluetoothGatt.GATT_SUCCESS) BleLoggerTag.d else BleLoggerTag.e,
            "Link quality: ${device.uuid}, PHY update status=${BluetoothGattStatus.getGattOperationStatusDescription(status)}, tx=${phyLabel(txPhy)}, rx=${phyLabel(rxPhy)}",
        )
    }

    /**
     * 请求设备 MTU。
     *
     * MTU 不作为私有服务 readiness 的前置条件，但 connectFinish 需要带最终 MTU 给 Dart。
     */
    private fun requestDeviceMtu(gatt: BluetoothGatt) {
        // 1. session 校验失败时不请求 MTU，避免 stale GATT 产生误导性回调。
        val device = currentExpectedDeviceForGatt(gatt, "request mtu") ?: return

        // 2. 使用配置中的目标 MTU，保持原插件行为。
        val targetMtu = device.belongConfig.mtu
        val requestStarted = gatt.requestMtu(targetMtu)
        recordTraceStep(gatt.device.address, "mtu", if (requestStarted) "started" else "failed", null, null, null)
        // 3. MTU 不是私有服务 readiness 的硬前置；如果请求本身没发出去，
        // 继续用默认 MTU 完成连接，避免因为不会到来的 onMtuChanged 卡住。
        if (!requestStarted) {
            sendLog(
                BleLoggerTag.e,
                "Connect call back: ${device.uuid} request mtu to = $targetMtu rejected, finish with default mtu = $DEFAULT_MTU",
            )
            connectingFlowFinish(gatt, DEFAULT_MTU)
            return
        }
        sendLog(BleLoggerTag.d, "Connect call back: ${device.uuid} enable all descriptor, request mtu to = $targetMtu")
    }

    /**
     * 根据 MTU 回调完成连接流程。
     *
     * 系统 bond 已在 Gate owner 获准后、服务发现前完成；这里仅上报 GATT readiness。
     * 真正的业务 connected 仍由 Dart 鉴权成功后调用 `deviceConnected`。
     */
    private fun connectingFlowFinish(gatt: BluetoothGatt, mtu: Int) {
        // 1. 再次校验 session，防止旧 MTU 回调错误完成新连接。
        val address = gatt.device.address
        val device = currentExpectedDeviceForGatt(gatt, "connect finish") ?: return
        val name = device.name
        // 2. GATT readiness 完成后上报 connectFinish，等待 Dart 业务认证后再进入 connected。
        recordTraceStep(address, "gatt_ready", "success", null, null, null)
        handleConnectState(address, name, BleConnectState.CONNECT_FINISH, mtu)
        // 3. 建连 hint 不能把已连上的 1M 链路切到 2M；在 GATT ready 后再请求一次。
        //    PHY 回调异步到达，不得挡住 connectFinish。
        BleAndroidPreferredPhy.requestLe2m(
            gatt = gatt,
            endpoint = address,
            reason = "connectFinish",
            logger = { sendLog(BleLoggerTag.d, it) },
        )
        sendLog(BleLoggerTag.d, "Connect call back: $address, connect finish")
    }

    /**
     * 解析本 callback 期望设备对应的 GATT session。
     *
     * Android passive `autoConnect=true` 在部分机型上可能把同一 callback 唤醒到其它已连设备
     * 的链路事件。这里先按 expected UUID 过滤，避免把戒指/另一条腿的系统事件误推进当前
     * autoReconnect 任务；非目标事件只忽略，不 close，防止误杀其它设备的正常 GATT。
     */
    private fun currentExpectedDeviceForGatt(gatt: BluetoothGatt, stage: String): BleDevice? {
        val address = gatt.device.address
        if (!expectedUuid.isNullOrBlank() && !address.equals(expectedUuid, ignoreCase = true)) {
            sendLog(
                BleLoggerTag.d,
                "Connect call back: $address $stage ignored, expected $expectedUuid",
            )
            return null
        }
        return currentDeviceForGatt(gatt, stage)
    }

    /**
     * 物理链路建立后启动高可靠策略。
     *
     * 先用 high priority 覆盖 service/CCCD/AUTH 初始突发，再由 5 秒周期根据真实流量回到
     * balanced；PHY 从 1M 起步，只有 RSSI 足够强才切 2M。
     */
    private fun startAdaptiveLinkMonitoring(gatt: BluetoothGatt, device: BleDevice) {
        stopAdaptiveLinkMonitoring()
        if (!device.belongConfig.androidHighReliabilityMode) {
            return
        }

        lastLinkActivityAtMs = SystemClock.elapsedRealtime()
        requestedPhy = BluetoothDevice.PHY_LE_1M
        requestConnectionPriority(gatt, high = true)
        requestPreferredPhy(gatt, BluetoothDevice.PHY_LE_1M, force = true)
        // 首次 RSSI 延后一个周期，避免刚连上时与 service/CCCD 初始化争用 GATT 操作窗口。
        // daemon Timer 不阻止进程退出；每个 tick 仍校验 exact GATT，旧 session 最迟一周期自清。
        adaptiveLinkTimer = Timer("ble-link-${device.uuid}", true).also { timer ->
            timer.scheduleAtFixedRate(
                object : TimerTask() {
                    override fun run() {
                        val currentDevice = currentExpectedDeviceForGatt(gatt, "adaptive link monitor")
                        if (currentDevice == null || !currentDevice.belongConfig.androidHighReliabilityMode) {
                            stopAdaptiveLinkMonitoring()
                            return
                        }
                        val useHighPriority = AndroidBleAdaptiveLinkPolicy.shouldUseHighPriority(
                            nowMs = SystemClock.elapsedRealtime(),
                            lastActivityAtMs = lastLinkActivityAtMs,
                        )
                        requestConnectionPriority(gatt, high = useHighPriority)
                        requestRemoteRssi(gatt, currentDevice)
                    }
                },
                AndroidBleAdaptiveLinkPolicy.RSSI_MONITOR_INTERVAL_MS,
                AndroidBleAdaptiveLinkPolicy.RSSI_MONITOR_INTERVAL_MS,
            )
        }
        sendLog(
            BleLoggerTag.d,
            "Link quality: ${device.uuid}, adaptive monitor started, initialPhy=1M, interval=${AndroidBleAdaptiveLinkPolicy.RSSI_MONITOR_INTERVAL_MS}ms",
        )
    }

    /** 高频收发只更新时间戳；priority 状态变化时才真正调用 framework。 */
    private fun noteLinkActivity(gatt: BluetoothGatt, device: BleDevice) {
        if (!device.belongConfig.androidHighReliabilityMode) {
            return
        }
        lastLinkActivityAtMs = SystemClock.elapsedRealtime()
        requestConnectionPriority(gatt, high = true)
    }

    /** 在同一 session 内切换 high/balanced；系统拒绝偏好不改变连接状态。 */
    @Synchronized
    private fun requestConnectionPriority(gatt: BluetoothGatt, high: Boolean) {
        if (isHighConnectionPriority == high) {
            return
        }
        val priority = if (high) {
            BluetoothGatt.CONNECTION_PRIORITY_HIGH
        } else {
            BluetoothGatt.CONNECTION_PRIORITY_BALANCED
        }
        val accepted = runCatching { gatt.requestConnectionPriority(priority) }.getOrElse { error ->
            sendLog(BleLoggerTag.e, "Link quality: ${gatt.device.address}, request priority exception=${error.message}")
            false
        }
        // 记录“已请求”而不是臆测 controller 真实参数；即使 framework 同步拒绝，也不能让
        // 高频音频 notify 对每一包重复调用。下一次 high/balanced 状态切换会自然重试。
        isHighConnectionPriority = high
        updateTraceRequestedPriority(
            gatt.device.address,
            if (high) "HIGH" else "BALANCED",
            accepted,
        )
        sendLog(
            if (accepted) BleLoggerTag.d else BleLoggerTag.e,
            "Link quality: ${gatt.device.address}, request priority=${if (high) "HIGH" else "BALANCED"}, accepted=$accepted",
        )
    }

    /** PHY 偏好只在 Android 8+ 可用；controller 可拒绝或覆盖，最终值由 onPhyUpdate 记录。 */
    @Synchronized
    private fun requestPreferredPhy(gatt: BluetoothGatt, phy: Int, force: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || (!force && requestedPhy == phy)) {
            return
        }
        val previousPhy = requestedPhy
        requestedPhy = phy
        val phyMask = when (phy) {
            BluetoothDevice.PHY_LE_2M -> BluetoothDevice.PHY_LE_2M_MASK
            else -> BluetoothDevice.PHY_LE_1M_MASK
        }
        val requested = runCatching {
            gatt.setPreferredPhy(
                phyMask,
                phyMask,
                BluetoothDevice.PHY_OPTION_NO_PREFERRED,
            )
        }.fold(
            onSuccess = { true },
            onFailure = { error ->
                sendLog(BleLoggerTag.e, "Link quality: ${gatt.device.address}, request PHY exception=${error.message}")
                false
            },
        )
        val trigger = when {
            phy == BluetoothDevice.PHY_LE_1M && previousPhy == BluetoothDevice.PHY_LE_2M -> "phy_fallback"
            phy == BluetoothDevice.PHY_LE_2M && previousPhy == BluetoothDevice.PHY_LE_1M -> "phy_promote"
            else -> "phy_initial"
        }
        recordTracePhyPolicy(
            gatt.device.address,
            trigger,
            phyLabel(phy),
            if (requested) "requested" else "failed",
        )
    }

    /** 单次只允许一个 RSSI 请求在途，避免监测与业务 GATT 操作形成额外排队。 */
    @Synchronized
    private fun requestRemoteRssi(gatt: BluetoothGatt, device: BleDevice) {
        if (isRssiReadPending) {
            return
        }
        val accepted = runCatching { gatt.readRemoteRssi() }.getOrElse { error ->
            sendLog(BleLoggerTag.e, "Link quality: ${device.uuid}, request RSSI exception=${error.message}")
            false
        }
        isRssiReadPending = accepted
        if (!accepted) {
            sendLog(BleLoggerTag.e, "Link quality: ${device.uuid}, request RSSI rejected")
        }
    }

    /** 停止当前 callback 的监测 owner；重复调用必须幂等。 */
    @Synchronized
    private fun stopAdaptiveLinkMonitoring() {
        adaptiveLinkTimer?.cancel()
        adaptiveLinkTimer = null
        isRssiReadPending = false
        isHighConnectionPriority = false
    }

    /** 所有 callback 内终态统一先撤销链路监测，再交回 manager 做 Gate teardown。 */
    private fun terminateSession(gatt: BluetoothGatt, state: BleConnectState, mtu: Int) {
        stopAdaptiveLinkMonitoring()
        securityGateAttempts.cancel(securityGateOwner(gatt))
        onSessionTerminal(gatt, state, mtu)
    }

    /** Security Supervisor 动作到连接终态的唯一映射。 */
    private fun BleAndroidSecurityRecoveryAction.toTerminalState(): BleConnectState = when (this) {
        BleAndroidSecurityRecoveryAction.RETRY -> BleConnectState.DISCONNECT_FROM_SYS
        BleAndroidSecurityRecoveryAction.EXHAUSTED -> BleConnectState.SECURITY_RECOVERY_EXHAUSTED
        BleAndroidSecurityRecoveryAction.MANUAL_FAILURE -> BleConnectState.BOUND_FAIL
        // exact registry 正常不会把 duplicate 送到这里；保守按普通断连 fail-closed。
        BleAndroidSecurityRecoveryAction.DUPLICATE_IGNORED -> BleConnectState.DISCONNECT_FROM_SYS
    }

    /** 将 Android PHY 常量转换为稳定日志文本，未知值仍保留原始数值。 */
    private fun phyLabel(phy: Int?): String = when (phy) {
        BluetoothDevice.PHY_LE_1M -> "1M"
        BluetoothDevice.PHY_LE_2M -> "2M"
        BluetoothDevice.PHY_LE_CODED -> "CODED"
        null -> "unknown"
        else -> "unknown($phy)"
    }

    private companion object {
        /** 与旧实现一致的默认 MTU 上报值。 */
        private const val DEFAULT_MTU = 247
    }
}
