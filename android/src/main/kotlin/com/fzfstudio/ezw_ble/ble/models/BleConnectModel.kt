package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_utils.gson.GsonSerializable

data class BleConnectModel(
    val uuid: String,
    val name: String,
    val connectState: BleConnectState,
    val mtu: Int = 247,
): GsonSerializable()
