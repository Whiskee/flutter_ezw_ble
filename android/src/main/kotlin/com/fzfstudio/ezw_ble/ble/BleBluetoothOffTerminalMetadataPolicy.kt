package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource

/** 一条发往 Dart 的连接终态身份；session 与 attempt 代次不可互相替代。 */
internal data class BleTerminalMetadata(
    val source: BleConnectSource,
    val sessionGeneration: Long,
    val attemptGeneration: Long,
)

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

    /**
     * 1、显式携带有效 session 的 exact callback 永远优先。
     * 2、业务已经 connected 后，某些 Android 系统断连出口只保留 uuid/GATT；此时从
     * 最后已接受 admission 补齐 source/session/attempt，避免 Dart 拒绝真实断连。
     * 3、没有有效 fallback 时保持原值，不能为尚未业务 connected 的失败 attempt
     * 伪造旧会话身份。
     */
    fun resolveTerminalMetadata(
        explicitSource: BleConnectSource,
        explicitSessionGeneration: Long,
        explicitAttemptGeneration: Long,
        fallbackAdmission: BleConnectionAdmission?,
    ): BleTerminalMetadata {
        if (explicitSource != BleConnectSource.UNKNOWN &&
            explicitSessionGeneration > 0L
        ) {
            return BleTerminalMetadata(
                source = explicitSource,
                sessionGeneration = explicitSessionGeneration,
                attemptGeneration = explicitAttemptGeneration,
            )
        }
        val acceptedFallback = fallbackAdmission.takeIf(::isEpochAccepted)
        return if (acceptedFallback != null) {
            BleTerminalMetadata(
                source = acceptedFallback.source,
                sessionGeneration = acceptedFallback.sessionGeneration,
                attemptGeneration = acceptedFallback.generation,
            )
        } else {
            BleTerminalMetadata(
                source = explicitSource,
                sessionGeneration = explicitSessionGeneration,
                attemptGeneration = explicitAttemptGeneration,
            )
        }
    }
}
