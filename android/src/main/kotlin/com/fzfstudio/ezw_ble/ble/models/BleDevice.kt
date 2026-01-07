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

class BleDevice(
    //  序列化时只输出名称
    @JsonAdapter(BleConfigOutAdapter::class)
    val belongConfig: BleConfig,
    val name: String,
    val uuid: String,
    val sn : String,
    var rssi: Int,
    var connectState: BleConnectState,
): GsonSerializable() {

    private val tag = "BleDevice"

    /// 缓存设备所含有的Gatt
    private var gatt: BluetoothGatt? = null
    private val writeAndReadList: MutableList<BleWriteAndRead> = Collections.synchronizedList(mutableListOf())

    ///========== Get
    val myGatt: BluetoothGatt?
        get() = gatt
    //  是否已经连接
    val isConnected: Boolean
        get() = connectState == BleConnectState.CONNECTED


    /**
     * 添加Gatt及其读写配置
     */
    fun update(gatt: BluetoothGatt, psType: Int? = null, write: BluetoothGattCharacteristic? = null, read: BluetoothGattCharacteristic? = null) {
        //  1、更新Gatt
        this.gatt = gatt
        //  2、检查是否要更新读写
        if (psType == null || write == null || read == null) {
            return
        }
        //  3、更新
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
        //  disconnect是用来断连设备但是不释放，便于重连，而且执行onConnectionStateChange的回调
        gatt?.disconnect()
        //  close是用来释放设备的，避免其他设备无法搜索以及连接
        gatt?.close()
        gatt = null
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
        //  1、初始化发送内容
        if (data == null) {
            Log.i(tag, "Send cmd: $uuid, PS type=$psType, data is null")
            return false
        }
        //  2、执行发送
        //  - 1.1、准备打印内容
        //  - 1.2、获取GATT和写服务
        val bleGatt = writeAndReadList.firstOrNull { it.psType == psType }
        val writeChars = bleGatt?.writeChars
        if (gatt == null || writeChars == null) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, psType).toMap())
            Log.i(tag, "Send cmd: $uuid, PS type=$psType, $data, no write chars found")
            return false
        }
        //  2、执行写操作
        val isSuccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = gatt?.writeCharacteristic(writeChars, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) ?: BluetoothStatusCodes.ERROR_UNKNOWN
            status == BluetoothStatusCodes.SUCCESS
        } else {
            writeChars.value = data
            gatt?.writeCharacteristic(writeChars) ?: false
        }
        if (!isSuccess) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, psType).toMap())
        }
        Log.i(tag, "Send cmd: $uuid is success = ${isSuccess}, name=$name, type=$psType, data length=${data.size}")
        return true
    }

}

///
class BleWriteAndRead(
    //  服务类型
    var psType: Int? = null,
    var writeChars: BluetoothGattCharacteristic? = null,
    var readChars: BluetoothGattCharacteristic? = null,
)