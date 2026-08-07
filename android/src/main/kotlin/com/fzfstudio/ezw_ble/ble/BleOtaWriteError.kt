package com.fzfstudio.ezw_ble.ble

/**
 * Android OTA no-wait 的同步提交错误。
 *
 * `sendCmdNoWait(psType=1)` 的成功只表示 native 已把数据提交给 Android GATT。
 * 任何提交前失败都必须经 MethodChannel 失败返回，避免 Dart 把未写入数据当作已发送。
 */
data class BleOtaWriteError(
    val code: String,
    val endpoint: String,
    val reason: String,
    val pending: Int = 0,
) {
    val details: Map<String, Any>
        get() = mapOf(
            "endpoint" to endpoint,
            "reason" to reason,
            "pending" to pending,
        )

    companion object {
        fun unavailable(endpoint: String, reason: String): BleOtaWriteError =
            BleOtaWriteError("ota_write_unavailable", endpoint, reason)

        fun unsupported(endpoint: String, reason: String): BleOtaWriteError =
            BleOtaWriteError("ota_write_unsupported", endpoint, reason)
    }
}
