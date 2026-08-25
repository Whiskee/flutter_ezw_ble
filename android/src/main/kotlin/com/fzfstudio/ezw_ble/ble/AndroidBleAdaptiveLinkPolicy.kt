package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice

/**
 * Android 高可靠 BLE 链路的纯策略边界。
 *
 * 建链先使用 1M 保留链路预算；连接后只有信号稳定且足够强时才升到 2M，RSSI 劣化时
 * 立即回退 1M。阈值之间保留迟滞区，避免人体遮挡边缘反复切 PHY。
 */
internal object AndroidBleAdaptiveLinkPolicy {
    /** 只有高于该强信号阈值才允许升到 2M。 */
    const val PROMOTE_TO_2M_RSSI_DBM = -60

    /** 低于该阈值立即回退到 1M，给 supervision timeout 留出恢复余量。 */
    const val FALLBACK_TO_1M_RSSI_DBM = -70

    /** RSSI 监测周期；兼顾遮挡响应速度和常驻连接功耗。 */
    const val RSSI_MONITOR_INTERVAL_MS = 5_000L

    /** 链路无收发超过该时间后恢复 balanced，避免 G2 全天常驻 high priority。 */
    const val HIGH_PRIORITY_IDLE_TIMEOUT_MS = 10_000L

    /** 高可靠配置统一从 1M 建链；未开启的配置保留历史 2M 行为。 */
    fun initialConnectPhyMask(highReliabilityMode: Boolean): Int =
        if (highReliabilityMode) BluetoothDevice.PHY_LE_1M_MASK else BluetoothDevice.PHY_LE_2M_MASK

    /**
     * 根据 RSSI 和当前请求的 PHY 返回下一目标。
     *
     * 中间迟滞区保持当前值，避免 -60/-70dBm 附近的采样抖动反复触发 controller 更新。
     */
    fun preferredPhy(currentPhy: Int, rssi: Int): Int = when {
        rssi >= PROMOTE_TO_2M_RSSI_DBM -> BluetoothDevice.PHY_LE_2M
        rssi <= FALLBACK_TO_1M_RSSI_DBM -> BluetoothDevice.PHY_LE_1M
        else -> currentPhy
    }

    /** 真实收发活跃时使用 high priority，空闲后回 balanced。 */
    fun shouldUseHighPriority(nowMs: Long, lastActivityAtMs: Long): Boolean =
        nowMs - lastActivityAtMs < HIGH_PRIORITY_IDLE_TIMEOUT_MS
}
