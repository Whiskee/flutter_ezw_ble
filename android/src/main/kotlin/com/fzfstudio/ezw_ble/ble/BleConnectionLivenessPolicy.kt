package com.fzfstudio.ezw_ble.ble

/**
 * Android 系统 GATT 查询结果。
 *
 * UNKNOWN 与 DISCONNECTED 必须区分：权限、蓝牙状态或系统查询异常时不能据此拆除一条
 * 仍可能有效的业务连接。
 */
internal enum class BleSystemGattConnectionState {
    CONNECTED,
    DISCONNECTED,
    UNKNOWN,
}

/** 业务连接存活对账允许执行的动作。 */
internal enum class BleConnectionLivenessAction {
    /** 本地与系统证据不足或连接仍然有效，不改变任何连接资源。 */
    NO_OP,
    /** native 已经进入长期回连，但 Dart 仍显示 connected；只补发一次系统断连终态。 */
    REPLAY_TERMINAL,
    /** native 仍标记 connected，但 GATT 已丢失或系统明确断连；走标准 teardown。 */
    TERMINATE_STALE_CONNECTED,
}

/**
 * 存活对账的纯决策输入。
 *
 * 决策层不访问 BluetoothGatt，便于锁定 UNKNOWN、去重以及 owner/epoch 保护边界。
 */
internal data class BleConnectionLivenessInput(
    val dartClaimsConnected: Boolean,
    val nativeBusinessConnected: Boolean,
    val hasExactGatt: Boolean,
    val systemGattState: BleSystemGattConnectionState,
    val hasEpochAcceptedAdmission: Boolean,
    val hasPersistentReconnectOwner: Boolean,
    val protectedByLifecycle: Boolean,
    val sessionAlreadyReconciled: Boolean,
    /** exact admission 尚未完成业务 connected，当前写失败不能反向终止这次建链。 */
    val connectionAttemptInProgress: Boolean,
)

/** Android 业务连接存活对账的单一决策表。 */
internal object BleConnectionLivenessPolicy {
    fun decide(input: BleConnectionLivenessInput): BleConnectionLivenessAction {
        // 1. 只有 Dart 当前仍声称 connected，且 native 仍持有合法 owner/epoch 时才允许纠偏。
        if (!input.dartClaimsConnected ||
            !input.hasEpochAcceptedAdmission ||
            !input.hasPersistentReconnectOwner ||
            input.protectedByLifecycle ||
            input.sessionAlreadyReconciled ||
            input.connectionAttemptInProgress
        ) {
            return BleConnectionLivenessAction.NO_OP
        }

        // 2. native 已经脱离业务 connected 并进入长期回连时，只补发终态，不能重复 teardown。
        if (!input.nativeBusinessConnected) {
            return BleConnectionLivenessAction.REPLAY_TERMINAL
        }

        // 3. native 仍认为 connected 时，只接受 GATT 丢失或系统明确断连作为拆链证据。
        if (!input.hasExactGatt ||
            input.systemGattState == BleSystemGattConnectionState.DISCONNECTED
        ) {
            return BleConnectionLivenessAction.TERMINATE_STALE_CONNECTED
        }

        // 4. 系统仍连接或无法权威查询时保持现状，避免权限异常制造假断连。
        return BleConnectionLivenessAction.NO_OP
    }
}
