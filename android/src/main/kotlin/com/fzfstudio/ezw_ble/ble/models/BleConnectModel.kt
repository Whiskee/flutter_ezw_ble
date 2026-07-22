package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_utils.gson.GsonSerializable

data class BleConnectModel(
    val uuid: String,
    val name: String,
    val connectState: BleConnectState,
    val mtu: Int = 247,
    val source: BleConnectSource = BleConnectSource.UNKNOWN,
    val sessionGeneration: Long = 0L,
    val attemptGeneration: Long = 0L,
    /** Serialized as the legacy session-generation field for old Dart consumers. */
    val generation: Long = sessionGeneration,
): GsonSerializable()
