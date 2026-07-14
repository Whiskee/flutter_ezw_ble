package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState

/** Gate 已释放后收到 GATT 终态时的 owner 判定。 */
internal enum class BlePostAdmissionTerminalDisposition {
    /** 业务 connected 仍由同一 GATT 持有；必须上报系统断连并重建 passive GATT。 */
    BUSINESS_CONNECTED_SESSION,

    /** callback 不再属于当前设备/GATT，只能忽略。 */
    STALE,
}

/**
 * `deviceConnected` 会释放 Gate admission，但不会释放业务 GATT。后续系统断连没有
 * current admission，因此必须用 GATT 对象身份 + 业务 connected 状态识别仍然有效的
 * session；旧 GATT 即使携带相同 endpoint/generation 也不能干扰新 attempt。
 */
internal object BlePostAdmissionTerminalPolicy {
    fun resolve(
        state: BleConnectState,
        gattAndSessionStillOwnDevice: Boolean,
        deviceIsBusinessConnected: Boolean,
    ): BlePostAdmissionTerminalDisposition =
        if (
            state == BleConnectState.DISCONNECT_FROM_SYS &&
            gattAndSessionStillOwnDevice &&
            deviceIsBusinessConnected
        ) {
            BlePostAdmissionTerminalDisposition.BUSINESS_CONNECTED_SESSION
        } else {
            BlePostAdmissionTerminalDisposition.STALE
        }
}
