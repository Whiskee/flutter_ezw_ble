package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource

/**
 * 蓝牙 transport 关闭会先清空 Gate/runtime 表，再向 Dart 上报系统断连。
 *
 * 终态必须沿用本次物理会话已被 Dart epoch guard 接受过的 metadata：连接仍在
 * Gate 内时取 current admission；业务已 connected、Gate 已释放时取长期 GATT
 * session 的 admission。未知来源或 0 sessionGeneration 不能作为终态事件的兜底值，
 * 否则 Dart 会拒绝它并保留过期的已连接状态。
 */
internal object BleBluetoothOffTerminalMetadataPolicy {
    fun resolve(
        currentAdmission: BleConnectionAdmission?,
        businessConnectedAdmission: BleConnectionAdmission?,
        lastBusinessConnectedAdmission: BleConnectionAdmission? = null,
    ): BleConnectionAdmission? =
        currentAdmission.takeIf(::isEpochAccepted)
            ?: businessConnectedAdmission.takeIf(::isEpochAccepted)
            ?: lastBusinessConnectedAdmission.takeIf(::isEpochAccepted)

    /** 业务 connected 与系统断连事件共用的最低 epoch 契约。 */
    fun isEpochAccepted(admission: BleConnectionAdmission?): Boolean =
            admission != null &&
            admission.source != BleConnectSource.UNKNOWN &&
            admission.sessionGeneration > 0L
}
