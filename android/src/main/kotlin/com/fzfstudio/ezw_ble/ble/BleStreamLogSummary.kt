package com.fzfstudio.ezw_ble.ble

/** 单个 GATT callback 的音频日志窗口；不持有 payload，也不跨 session 混算。 */
internal class BleStreamLogSummary(private val nowMillis: () -> Long) {
    private var startedAt: Long? = null
    private var packets = 0L
    private var bytes = 0L

    /** 首包启动 5s 窗口，触发汇总的包计入本窗口，不额外启动 timer 或尾包日志。 */
    @Synchronized
    fun record(byteCount: Int): String? {
        val now = nowMillis()
        val start = startedAt ?: now.also { startedAt = it }
        packets++
        bytes += byteCount
        if (now - start < 5_000L) return null
        val summary = "packets=$packets, bytes=$bytes, windowMs=${now - start}"
        startedAt = null
        packets = 0L
        bytes = 0L
        return summary
    }
}
