package com.fzfstudio.ezw_ble.ble.models

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import android.util.Log
import com.fzfstudio.ezw_ble.ble.BleEC
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.enums.BleUuidType
import com.fzfstudio.ezw_utils.extension.toHexString
import kotlinx.coroutines.sync.Semaphore

class BleDevice(
    val name: String,
    val uuid: String,
    val sn : String,
    var rssi: Int,
    val connectState: BleConnectState,
) {

    private val tag = "BleDevice"

    /// 缓存设备所含有的Gatt
    val gattMap: MutableMap<BleUuidType, BleGatt> = mutableMapOf()

    ///========== Get
    val myGatt: BluetoothGatt?
        get() = gattMap[BleUuidType.COMMON]?.gatt
    //  是否已经连接
    val isConnected: Boolean
        get() = myGatt?.connect() == true

    ///
    private val gattResponseSemaphore: Semaphore = Semaphore(1)

    /**
     * 执行写操作
     */
    fun writeCharacteristic(data: ByteArray?, uuidType: BleUuidType): Boolean {
        //  1、初始化发送内容
        if (data == null) {
            Log.i(tag, "Send cmd: $uuid, type=$uuidType, data is null")
            return false
        }
        //  - 1.1、准备打印内容
        val dataHex = data.toHexString()
        //  - 1.2、获取GATT和写服务
        val bleGatt = gattMap[uuidType]
        val gatt = bleGatt?.gatt
        val writeChars = bleGatt?.writeChars
        if (gatt == null || writeChars == null) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, uuidType).toMap())
            Log.i(tag, "Send cmd: $uuid, type=$uuidType, $dataHex, no write chars found")
            return false
        }
        //  2、执行写操作
        var isSuccess = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = gatt.writeCharacteristic(writeChars, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
            isSuccess = status == BluetoothStatusCodes.SUCCESS
            Log.i(tag, "Send cmd: uuid=$uuid\ntype=$uuidType\ndata=$dataHex\nwrite status = $status;")
        } else {
            writeChars.value = data
            isSuccess = gatt.writeCharacteristic(writeChars)
            Log.i(tag, "Send cmd: $uuid, type=$uuidType, $dataHex, isSuccess = $isSuccess")
        }
        if (!isSuccess) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid, uuidType).toMap())
        }
        return gattResponseSemaphore.tryAcquire()
    }

    /**
     * 释放响应
     */
    fun gattResponseArrived() = gattResponseSemaphore.release()
}

///
class BleGatt(
    val gatt: BluetoothGatt?,
    var writeChars: BluetoothGattCharacteristic? = null,
    var readChars: BluetoothGattCharacteristic? = null,
)