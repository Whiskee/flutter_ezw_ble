package com.fzfstudio.ezw_ble.ble.models

import java.io.Serializable

data class BleConnectedDevice(
    val writeChars: String,
    val readChars: String,
    val isConnected: Boolean
): Serializable
