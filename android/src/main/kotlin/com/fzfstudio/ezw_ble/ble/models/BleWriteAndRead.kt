package com.fzfstudio.ezw_ble.ble.models

import android.bluetooth.BluetoothGattCharacteristic

/**
 * 某个私有服务类型对应的读写 characteristic 缓存。
 *
 * 该对象只在一次 GATT session 内有效；断连/重连后必须由服务发现流程重新填充。
 */
class BleWriteAndRead(
    /** 私有服务类型。 */
    var psType: Int? = null,
    /** 用于发送命令的 write characteristic。 */
    var writeChars: BluetoothGattCharacteristic? = null,
    /** 用于接收 notify/read 数据的 read characteristic。 */
    var readChars: BluetoothGattCharacteristic? = null,
)
