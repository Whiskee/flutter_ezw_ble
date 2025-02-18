package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable

data class BleConnectModel(
    val uuid: String,
    val connectState: BleConnectState,
): GsonSerializable()
