package com.fzfstudio.ezw_ble.ble

/**
 * Android OTA no-wait 的提交/背压错误。
 *
 * `sendCmdNoWait(psType=1)` 只有在对应 characteristic write callback 成功后才完成。
 * 同步 BUSY 会在原生队列保留原包；终态错误必须经 MethodChannel 返回，避免 Dart 把未写入
 * 或仍在 GATT 单槽位等待的数据当作已发送。
 */
data class BleOtaWriteError(
    val code: String,
    val endpoint: String,
    val reason: String,
    val pending: Int = 0,
    val waitSeconds: Double? = null,
    val status: Int? = null,
    val statusName: String? = null,
) {
    val details: Map<String, Any>
        get() = buildMap {
            put("endpoint", endpoint)
            put("reason", reason)
            put("pending", pending)
            waitSeconds?.let { put("wait", it) }
            status?.let { put("status", it) }
            statusName?.let { put("statusName", it) }
        }

    companion object {
        fun unavailable(
            endpoint: String,
            reason: String,
            pending: Int = 0,
            status: Int? = null,
            statusName: String? = null,
        ): BleOtaWriteError = BleOtaWriteError(
            code = "ota_write_unavailable",
            endpoint = endpoint,
            reason = reason,
            pending = pending,
            status = status,
            statusName = statusName,
        )

        fun unsupported(endpoint: String, reason: String): BleOtaWriteError =
            BleOtaWriteError("ota_write_unsupported", endpoint, reason)

        fun cancelled(endpoint: String, reason: String, pending: Int): BleOtaWriteError =
            BleOtaWriteError(
                code = "ota_write_cancelled",
                endpoint = endpoint,
                reason = reason,
                pending = pending,
            )

        fun stalled(
            endpoint: String,
            reason: String,
            waitSeconds: Double,
            pending: Int,
            status: Int? = null,
        ): BleOtaWriteError = BleOtaWriteError(
            code = "ota_write_stalled",
            endpoint = endpoint,
            reason = reason,
            pending = pending,
            waitSeconds = waitSeconds,
            status = status,
        )
    }
}
