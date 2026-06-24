package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice

/**
 * Android 前台连接的路由解析结果。
 *
 * 这个对象只描述“本次 connect 请求应该怎么走”，不持有 GATT，也不直接改变连接状态。
 * 这样 `BleManager.connect` 可以把复杂判断拆成可审阅的步骤：先解析身份与缓存，再决定是否
 * 需要扫描补偿，最后才打开 GATT。
 */
internal data class BleConnectPlan(
    /** Dart 层传入并归一化后的连接请求。 */
    val request: BleConnectRequest,
    /** 请求命中的 BLE 配置，用于连接超时、私有服务和自动回连策略。 */
    val config: BleConfig,
    /** Android BluetoothAdapter 按地址解析出来的系统设备句柄。 */
    val remoteDevice: BluetoothDevice,
    /** 插件本地连接缓存中已有的设备；为空表示这是新的连接身份。 */
    val cachedDevice: BleDevice?,
    /** 最近一次扫描命中的稳定广播名，用于补齐 `remoteDevice.name == null` 的场景。 */
    val cachedScanName: String?,
    /** 本次连接最终使用的设备名；为空时不能继续绑定类设备连接。 */
    val resolvedName: String?,
    /** Android 系统 GATT 层是否已经认为该设备处于 connected。 */
    val isOsConnected: Boolean,
    /** 本地缓存是否明确要求先扫描刷新 Android BLE 协议栈地址类型信息。 */
    val needsScanForCache: Boolean,
    /** 首次连接是否因为系统设备名为空而需要先扫描补齐广播名。 */
    val needsScanForName: Boolean,
) {
    /**
     * 判断本次连接是否需要在打开 GATT 前先刷新扫描缓存。
     *
     * 系统已连接的设备通常不再广播，因此 `isOsConnected` 为 true 时不能强行扫描等待命中，
     * 否则会把一个已经可直连的设备误判为 `NO_DEVICE_FOUND`。
     */
    fun shouldRefreshScanBeforeGatt(): Boolean {
        // 1. directConnect 表示调用方已经明确要求跳过扫描路由。
        if (request.directConnect) return false

        // 2. 系统已 connected 的设备不一定广播，扫描补偿反而会制造假失败。
        if (isOsConnected) return false

        // 3. 只有缓存要求刷新或缺失稳定名称时，才需要先扫描再回到 connect。
        return needsScanForCache || needsScanForName
    }

    /**
     * 判断是否需要进入 scan-then-connect 路径等待目标重新出现在扫描缓存中。
     *
     * 这个阶段不同于 `shouldRefreshScanBeforeGatt`：前者是补齐系统缓存/设备名，后者是前台
     * 主动连接时避免盲连一个当前完全不可见的设备。
     */
    fun shouldWaitForVisibleAdvertisement(isVisibleInScan: Boolean): Boolean {
        // 1. directConnect 明确跳过扫描可见性检查。
        if (request.directConnect) return false

        // 2. 扫描补偿重入时已经等过一次目标命中，不能被自己设置的 connecting 状态挡住。
        if (request.isWaitingDevice) return false

        // 3. 系统已 connected 的设备可能不再广播，不能把不可见当作不存在。
        if (isOsConnected) return false

        // 4. 只有当前扫描缓存确实没看到目标，才进入待扫描队列。
        return !isVisibleInScan
    }
}
