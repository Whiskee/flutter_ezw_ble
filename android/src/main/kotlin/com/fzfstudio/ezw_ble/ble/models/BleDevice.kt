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

class BleDevice(
    //  序列化时只输出名称
    @JsonAdapter(BleConfigOutAdapter::class)
    val belongConfig: BleConfig,
    val name: String,
    val uuid: String,
    val sn : String,
    var rssi: Int,
    val connectState: BleConnectState,
): GsonSerializable() {

    private val tag = "BleDevice"

    /// 缓存设备所含有的Gatt
    val gattMap: MutableMap<Int, BleGatt> = mutableMapOf()

    ///========== Get
    val myGatt: BluetoothGatt?
        get() = gattMap[0]?.gatt
    //  是否已经连接
    val isConnected: Boolean
        get() = myGatt?.connect() == true

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
        //  - 1.1、准备打印内容
        //  - 1.2、获取GATT和写服务
        val bleGatt = gattMap[psType]
        val gatt = bleGatt?.gatt
        val writeChars = bleGatt?.writeChars
        if (gatt == null || writeChars == null) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, psType).toMap())
            Log.i(tag, "Send cmd: $uuid, PS type=$psType, $data, no write chars found")
            return false
        }
        //  2、执行写操作
        val isSuccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = gatt.writeCharacteristic(writeChars, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
            status == BluetoothStatusCodes.SUCCESS
        } else {
            writeChars.value = data
            gatt.writeCharacteristic(writeChars)
        }
        if (!isSuccess) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, psType).toMap())
        }
        Log.i(tag, "Send cmd: $uuid is success = ${isSuccess}\n--type=$psType\n--length=${data.size}\n--data=${data.toHexString()}")
        return true
    }
}

///
class BleGatt(
    val gatt: BluetoothGatt?,
    var writeChars: BluetoothGattCharacteristic? = null,
    var readChars: BluetoothGattCharacteristic? = null,
)