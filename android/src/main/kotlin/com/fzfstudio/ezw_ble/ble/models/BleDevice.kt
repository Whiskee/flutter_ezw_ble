package com.fzfstudio.ezw_ble.ble.models

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import android.util.Log
import com.fzfstudio.ezw_ble.ble.BleEC
import com.fzfstudio.ezw_ble.ble.models.enums.BleConfigOutAdapter
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_utils.gson.GsonSerializable
import com.google.gson.annotations.JsonAdapter
import kotlinx.coroutines.delay
import java.util.Collections
import java.util.Timer

/**
 * Android 原生层缓存的一台 BLE 设备及其 GATT session。
 *
 * 该对象同时保存展示身份、连接状态、当前 BluetoothGatt、各私有服务的读写特征和连接超时器。
 * 它不负责发起连接；连接入口由 `BleManager` 控制，设备对象只承载一条 session 的运行态。
 */
class BleDevice(
    /** 设备所属配置；序列化给 Dart 时只输出配置名。 */
    @JsonAdapter(BleConfigOutAdapter::class)
    val belongConfig: BleConfig,
    /** 当前稳定设备名。 */
    val name: String,
    /** Android address / 插件 uuid。 */
    val uuid: String,
    /** 业务序列号，用于左右腿/多设备聚合。 */
    val sn: String,
    /** 最近一次扫描或 RSSI 读取到的信号值。 */
    var rssi: Int,
    /** 当前连接状态。 */
    @Volatile
    var connectState: BleConnectState,
    /** 异常断连/超时后，下一次重连是否需要先扫描刷新 Android 协议栈缓存。 */
    @Volatile
    var needsScanBeforeConnect: Boolean = false,
): GsonSerializable() {

    /** Android logcat tag。 */
    private val tag = "BleDevice"

    /** 当前 session 使用的 BluetoothGatt；释放后必须置空，避免僵尸 connected 状态误判。 */
    @Volatile
    private var gatt: BluetoothGatt? = null

    /** 各私有服务类型对应的 write/read characteristic 缓存。 */
    private val writeAndReadList: MutableList<BleWriteAndRead> = Collections.synchronizedList(mutableListOf())

    /** 连接/GATT readiness 超时器，连接成功或释放 session 时必须取消。 */
    @Volatile
    var timeoutTimer: Timer? = null

    /** 当前 BluetoothGatt，只读暴露给 manager。 */
    val myGatt: BluetoothGatt?
        get() = gatt

    /** 业务层确认后的 connected 状态。 */
    val isConnected: Boolean
        get() = connectState == BleConnectState.CONNECTED

    /**
     * 更新当前 GATT 或某个私有服务的读写 characteristic。
     *
     * 物理连接成功时只传入 gatt；服务发现完成后会携带 psType/write/read 更新具体通道。
     */
    fun update(gatt: BluetoothGatt, psType: Int? = null, write: BluetoothGattCharacteristic? = null, read: BluetoothGattCharacteristic? = null) {
        // 1. 总是先刷新 GATT 句柄，确保后续回调和写入都使用最新 session。
        this.gatt = gatt

        // 2. 没有完整私有服务参数时，本次调用只更新 GATT，不改变 characteristic 缓存。
        if (psType == null || write == null || read == null) {
            return
        }

        // 3. 同一个 psType 只保留最新 characteristic，避免服务重发现后写到旧对象。
        writeAndReadList.removeAll { it.psType == psType }
        writeAndReadList.add(BleWriteAndRead(psType, write, read))
    }

    /**
     * 释放Gatt并清空所有读写服务
     *
     *  disconnect是用来断连设备但是不释放，便于重连，而且执行onConnectionStateChange的回调
     *  close是用来释放设备的，避免其他设备无法搜索以及连接
     *
     *  在这个函数的场景中，disconnect是不会执行onConnectionStateChange回调的，因为立马执行了close，主动做了释放
     */
    fun releaseAndClear() {
        // 1. 取消连接超时定时器，避免释放 GATT 后仍触发 timeout。
        timeoutTimer?.cancel()
        timeoutTimer = null

        // 2. 先 disconnect 再 close，给 Android 协议栈一个正常断连信号。
        gatt?.disconnect()

        // 3. close 释放 native GATT 资源，否则后续扫描/连接可能被旧 session 占用。
        gatt?.close()
        gatt = null

        // 4. 清空读写特征缓存；每次物理回连都必须重新 discover services/enable notify。
        writeAndReadList.clear()
    }

    /**
     * 执行写操作
     *
     * @param data 指令数据
     * @param psType 私有服务类型
     *
     */
    @OptIn(ExperimentalStdlibApi::class)
    fun writeCharacteristic(data: ByteArray?, psType: Int): Boolean {
        // 1. 空 payload 不能写入，直接返回失败并保留日志。
        if (data == null) {
            Log.i(tag, "Send cmd: $uuid, PS type=$psType, data is null")
            return false
        }

        // 2. 按私有服务类型查找对应 write characteristic。
        val bleGatt = writeAndReadList.firstOrNull { it.psType == psType }
        val writeChars = bleGatt?.writeChars

        // 3. GATT 或 write characteristic 缺失说明 readiness 尚未完成，必须回传失败事件。
        if (gatt == null || writeChars == null) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, psType).toFlutterMap())
            Log.i(tag, "Send cmd: $uuid, PS type=$psType, $data, no write chars found")
            return false
        }

        // 4. Android 13+ 使用新 writeCharacteristic API，旧系统仍使用 value + write 兼容路径。
        val isSuccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = gatt?.writeCharacteristic(writeChars, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) ?: BluetoothStatusCodes.ERROR_UNKNOWN
            status == BluetoothStatusCodes.SUCCESS
        } else {
            writeChars.value = data
            gatt?.writeCharacteristic(writeChars) ?: false
        }

        // 5. 原生写入失败时立即回传失败事件，避免 Dart 命令等待超时后才感知。
        if (!isSuccess) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, psType).toFlutterMap())
        }

        // 6. 发送日志只记录长度，不展开 payload，避免大量二进制数据污染 logcat。
        Log.i(tag, "Send cmd: $uuid is success = ${isSuccess}, name=$name, type=$psType, data length=${data.size}")
        return isSuccess
    }

    /**
     * OTA no-wait 只能在 characteristic 声明 no-response 写能力时放行。
     * 普通通道保留历史行为；该检查只给 BleManager 的 OTA fail-closed 分支使用。
     */
    fun supportsWriteWithoutResponse(psType: Int): Boolean {
        val writeChars = writeAndReadList.firstOrNull { it.psType == psType }?.writeChars
            ?: return false
        return writeChars.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
    }

}
