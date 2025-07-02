package com.fzfstudio.ezw_ble.ble.models

import java.util.Timer

/// 连接缓存数据
data class BleConnectTemp(
    val belongConfig: BleConfig,
    val uuid: String,
    val name: String,
    val sn: String,
    var afterUpgrade: Boolean,
) {
    //  连接超时定时器
    var timeoutTimer: Timer? = null
}