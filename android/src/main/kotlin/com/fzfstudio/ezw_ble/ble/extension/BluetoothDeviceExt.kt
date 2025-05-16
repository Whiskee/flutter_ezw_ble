package com.fzfstudio.ezw_ble.ble.extension

import android.bluetooth.BluetoothDevice
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.BleDevice

fun BluetoothDevice.toBleDevice(belongConfig: BleConfig, sn: String, rssi: Int) =
    BleDevice(belongConfig, name, address, sn, rssi, BleConnectState.NONE)