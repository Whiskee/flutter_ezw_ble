package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource

/**
 * 自动回连 task 的 attempt-scoped source 迁移规则。
 *
 * manual 在物理 callback 前不允许被 lifecycle 重入 auto 降级；业务成功或当前
 * attempt 终止后，后续长期回连必须恢复 autoReconnect。
 */
internal object BleReconnectSourcePolicy {
    fun onArm(
        current: BleConnectSource,
        incoming: BleConnectSource,
        businessConnected: Boolean,
    ): BleConnectSource = if (
        incoming == BleConnectSource.MANUAL_RECONNECT ||
        current != BleConnectSource.MANUAL_RECONNECT ||
        businessConnected
    ) {
        incoming
    } else {
        current
    }

    fun afterTerminalAttempt(): BleConnectSource = BleConnectSource.AUTO_RECONNECT

    /** 蓝牙关闭已使旧 manual session/generation 失效，恢复必须创建新的自动 attempt。 */
    fun afterTransportReset(): BleConnectSource = BleConnectSource.AUTO_RECONNECT
}
