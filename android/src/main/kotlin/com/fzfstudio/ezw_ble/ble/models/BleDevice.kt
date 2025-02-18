package com.fzfstudio.ezw_ble.ble.models

import android.bluetooth.BluetoothGatt

class BleDevice(
    val name: String,
    val uuid: String,
    val sn : String,
    var rssi: Int,
    val connectState: BleConnectState,
) {
    var gatt: BluetoothGatt? = null

    ///========== Get
    //  是否已经连接
    val isConnected: Boolean
        get() = gatt?.connect() == true
}