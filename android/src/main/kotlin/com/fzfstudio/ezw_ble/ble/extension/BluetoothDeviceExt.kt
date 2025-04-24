package com.fzfstudio.ezw_ble.ble.extension

import android.bluetooth.BluetoothDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.BleDevice

fun BluetoothDevice.toBleDevice(sn: String, rssi: Int) =
    BleDevice(name, address, sn, rssi, BleConnectState.NONE)