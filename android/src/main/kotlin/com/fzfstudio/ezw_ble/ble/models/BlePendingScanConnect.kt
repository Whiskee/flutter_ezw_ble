package com.fzfstudio.ezw_ble.ble.models

/**
 * 扫描命中后再连接的待处理请求。
 *
 * Android 协议栈可能缓存 MAC/名称但设备已不在广播范围内；非 directConnect 时
 * 必须先看到扫描结果再 connectGatt，否则应 fast-fail 为 noDeviceFound。
 */
data class BlePendingScanConnect(
    val belongConfig: String,
    val uuid: String,
    val name: String,
    val sn: String,
    val afterUpgrade: Boolean,
    val directConnect: Boolean,
    val startTimeMs: Long = System.currentTimeMillis(),
)
