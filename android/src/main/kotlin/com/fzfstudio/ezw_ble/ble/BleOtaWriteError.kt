package com.fzfstudio.ezw_ble.ble

/**
 * 使用无应答批量写队列的通道标识。
 *
 * 只用于日志前缀和 typed error code，让排障能直接区分是 OTA 还是文件传输失败；
 * 通道之间的队列实例、pending 和取消边界始终各自独立。
 */
internal object BleWriteChannel {
    const val OTA = "ota"
    const val FILE = "file"
}

/**
 * Android 无应答写(OTA / 文件批次)的提交/背压错误。
 *
 * `sendCmdNoWait(psType=1)` 与 `sendOtaPacketBatch` / `sendFilePacketBatch` 都只有在对应
 * characteristic write callback 成功后才完成。同步 BUSY 会在原生队列保留原包；终态错误必须经
 * MethodChannel 返回，避免 Dart 把未写入或仍在 GATT 单槽位等待的数据当作已发送。
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
            channel: String = BleWriteChannel.OTA,
        ): BleOtaWriteError = BleOtaWriteError(
            code = "${channel}_write_unavailable",
            endpoint = endpoint,
            reason = reason,
            pending = pending,
            status = status,
            statusName = statusName,
        )

        fun unsupported(
            endpoint: String,
            reason: String,
            channel: String = BleWriteChannel.OTA,
        ): BleOtaWriteError =
            BleOtaWriteError("${channel}_write_unsupported", endpoint, reason)

        fun cancelled(
            endpoint: String,
            reason: String,
            pending: Int,
            channel: String = BleWriteChannel.OTA,
        ): BleOtaWriteError =
            BleOtaWriteError(
                code = "${channel}_write_cancelled",
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
            channel: String = BleWriteChannel.OTA,
        ): BleOtaWriteError = BleOtaWriteError(
            code = "${channel}_write_stalled",
            endpoint = endpoint,
            reason = reason,
            pending = pending,
            waitSeconds = waitSeconds,
            status = status,
        )
    }
}
