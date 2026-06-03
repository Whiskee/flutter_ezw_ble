package com.fzfstudio.ezw_ble.ble.extension

import android.bluetooth.BluetoothDevice
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.BleDevice

fun resolveBleDeviceName(
    remoteName: String?,
    requestName: String?,
    cachedScanName: String?,
): String? = listOf(remoteName, requestName, cachedScanName)
    .firstOrNull { !it.isNullOrBlank() }

fun BluetoothDevice.toBleDevice(
    belongConfig: BleConfig,
    resolvedName: String,
    sn: String,
    rssi: Int,
) = BleDevice(
    belongConfig,
    resolvedName,
    address,
    sn,
    rssi,
    BleConnectState.NONE,
)