package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable

data class BleMatchDevice(
    val sn: String,
    val devices: List<BleDevice>,
): GsonSerializable() {

    val belongConfig: String
        get() = devices.first().beLongConfig

}
