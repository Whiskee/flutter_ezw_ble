package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import com.fzfstudio.ezw_ble.ble.models.BleCmd
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BluetoothGattStatus
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import java.util.LinkedList
import java.util.Queue

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
    /** 真实物理连接只提交给全局 Gate；Gate owner 才能开始 service discovery。 */
    private val onPhysicalConnected: (BluetoothGatt, BleDevice) -> Unit,
    /** 当前 session 进入终态时，由 manager 先释放 Gate、再清理状态并启动下一条 pipeline。 */
    private val onSessionTerminal: (BluetoothGatt, BleConnectState, Int) -> Unit,
    /** 查询系统蓝牙是否仍可用；蓝牙关闭时断连由系统状态监听统一处理。 */
    private val isBluetoothEnabled: () -> Boolean,
    /** 处理 ATT/GATT 操作返回授权不足；连接状态回调不得调用这个恢复入口。 */
    private val recoverInsufficientAuthorization: (BluetoothGatt, BleDevice) -> Unit,
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

        // 4. 蓝牙关闭时不在这里释放，避免和 BleStateListener 对同一批设备重复断连。
        if (!isBluetoothEnabled()) {
            sendLog(
                BleLoggerTag.e,
                "Connect call back: $address, not handle disconnect form state change, will call disconnect method in the ble state Listener",
            )
            return
        }

        // 5. 断连会使本 session 的 GATT readiness 失效。
        isPrivateServiceReady = false
        val device = currentExpectedDeviceForGatt(gatt, "connection disconnected") ?: return
        val connectionStatus = BluetoothGattStatus.getConnectionStatusDescription(status)

        // 6. 连接状态回调中的 status 是 HCI/controller 断连原因，不是 ATT/GATT 操作码。
        //    例如 status 8 在这里表示连接超时；只有 descriptor/characteristic 回调里的 8
        //    才能按 GATT_INSUFFICIENT_AUTHORIZATION 解释和记录。

        // 7. 当前 active GATT 在 connecting 阶段收到断连，说明本轮 connectGatt 已经失败。
        //    不能继续静默 keep connecting：G2 第二条腿会等满 timeout，甚至在部分机型上丢失终态。
        //    stale GATT 已在 currentExpectedDeviceForGatt 里过滤，这里可以安全落本轮 timeout。
        if (device.connectState.isConnecting) {
            sendLog(
                BleLoggerTag.e,
                "Connect call back: $address disconnected while connecting, fail active connect as timeout, code=$connectionStatus",
            )
            onSessionTerminal(gatt, BleConnectState.TIMEOUT, DEFAULT_MTU)
            return
        }

        // 8. 释放 native GATT 资源；不 close 会让后续连接占住旧 binder session。
        try {
            gatt.close()
        } catch (closeError: Exception) {
            sendLog(BleLoggerTag.e, "Connect call back: $address close gatt exception: ${closeError.message}")
        }

        // 9. 用户/超时主动断连已经有明确状态，不再二次上报系统断连。
        val explicitDisconnectState = consumeDisconnectingState(device.uuid)
        if (explicitDisconnectState != null) {
            sendLog(
                BleLoggerTag.e,
                "Connect call back: $address is disconnecting witch state = $explicitDisconnectState, stop disconnect flow form system",
            )
            return
        }

        // 10. 非主动断连统一上报系统断连，由 manager 决定是否调度自动回连。
        sendLog(
            BleLoggerTag.e,
            "Connect call back: $address state = STATE_DISCONNECTED(code:$connectionStatus)",
        )
        onSessionTerminal(gatt, BleConnectState.DISCONNECT_FROM_SYS, DEFAULT_MTU)
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
            onSessionTerminal(gatt, BleConnectState.SERVICE_FAIL, DEFAULT_MTU)
            sendLog(BleLoggerTag.e, "Connect call back: $address, discover service failure")
            return
        }

        // 3. 按配置逐个解析私有服务，任何一个 write/read 缺失都不能宣告 connectFinish。
        isPrivateServiceReady = true
        currentDevice.belongConfig.privateServices.forEach { privateService ->
            val service = gatt.getService(privateService.serviceUUID)
            val writeChars = service?.getCharacteristic(privateService.writeCharsUUID)
            if (writeChars == null) {
                sendLog(BleLoggerTag.e, "Connect call back: $address, ${privateService.service}, write characteristic not found")
                onSessionTerminal(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
                isPrivateServiceReady = false
                return
            }

            val readChars = service.getCharacteristic(privateService.readCharsUUID)
            if (readChars == null) {
                sendLog(BleLoggerTag.e, "Connect call back: $address, ${privateService.service}, read characteristic not found")
                onSessionTerminal(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
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

        // 6. 如果任一私有服务失败，等待失败状态处理，不再继续写 descriptor。
        if (!isPrivateServiceReady) {
            return
        }

        // 7. 所有 service/characteristic 都存在后，开始串行写 CCCD。
        processNextDescriptor(gatt)
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
            descriptorQueue.clear()
            inFlightDescriptorPsType = null
            isPrivateServiceReady = false
            val operationStatus = BluetoothGattStatus.getGattOperationStatusDescription(status)
            if (status == BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION) {
                // Descriptor write 已进入 GATT readiness 阶段；这里的 8 是 ATT/GATT 授权不足，
                // 先恢复 cache/bond 视图，再按原失败语义终止为 CHARS_FAIL 触发重试。
                recoverInsufficientAuthorization(gatt, device)
            }
            sendLog(
                BleLoggerTag.e,
                "Connect call back: ${gatt.device.address} descriptor write failed, status=$operationStatus",
            )
            onSessionTerminal(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
            return
        }

        // 4. 当前 descriptor 已完成，继续写下一个；队列空时会请求 MTU。
        inFlightDescriptorPsType?.let { device.markNotifyReady(it) }
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

        // 3. 业务 connected 后写 characteristic 返回授权不足，说明系统 GATT/bond 视图已拒绝。
        //    先恢复本端缓存，再以系统断连终止本 session；不能继续 poll/writeNext 消费发送队列。
        val operationStatus = BluetoothGattStatus.getGattOperationStatusDescription(status)
        if (status == BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION) {
            recoverInsufficientAuthorization(gatt, device)
            sendLog(BleLoggerTag.e, "Send cmd: $address, write failed, status=$operationStatus, terminal=DISCONNECT_FROM_SYS")
            onSessionTerminal(gatt, BleConnectState.DISCONNECT_FROM_SYS, DEFAULT_MTU)
            return
        }

        // 4. 其余 characteristic write 状态交给 manager 精确匹配普通/OTA owner；OTA Future
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
        sendLog(
            BleLoggerTag.d,
            "Connect call back: ${gatt.device.address} change mtu ${if (status == BluetoothGatt.GATT_SUCCESS) "success" else "fail"}, new mtu value = $mtu, connecting flow is finish",
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
            onSessionTerminal(gatt, BleConnectState.CHARS_FAIL, DEFAULT_MTU)
        }
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

    private companion object {
        /** 与旧实现一致的默认 MTU 上报值。 */
        private const val DEFAULT_MTU = 247
    }
}
