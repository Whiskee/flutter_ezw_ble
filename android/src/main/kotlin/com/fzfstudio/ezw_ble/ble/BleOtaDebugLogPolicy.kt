package com.fzfstudio.ezw_ble.ble

/**
 * Android 仅把 OTA 成功逐包详情交给宿主 Debug 设置；错误、阶段与其它 BLE 日志保持原样。
 * 独立静态策略允许宿主在 BLE 初始化前同步设置，不能因日志开关创建 manager 或改写 owner。
 */
internal object BleOtaDebugLogPolicy {
    // MethodChannel 与 GATT callback 可能在不同线程；下一条日志直接读取新值，无构建/环境分流。
    @Volatile
    var enabled: Boolean = false
        private set

    fun setEnabled(enabled: Boolean) {
        this.enabled = enabled
    }

    /** inline lazy producer 防止关闭时仍构造每包字符串；不得包围任何写入或完成逻辑。 */
    inline fun logPacketDetail(logger: (String) -> Unit, message: () -> String) {
        if (enabled) logger(message())
    }

    /** 未识别通道和所有失败保留诊断，只有已确认 OTA 通道的成功 callback 才能静默。 */
    inline fun logWriteCallback(
        psType: Int?,
        success: Boolean,
        logger: (String) -> Unit,
        message: () -> String,
    ) {
        if (psType != 1 || !success || enabled) logger(message())
    }

    /** 已成功分发的 OTA notify 元数据也是逐包详情；未知/其它通道仍保留原诊断。 */
    inline fun logReceiveCallback(
        psType: Int?,
        logger: (String) -> Unit,
        message: () -> String,
    ) {
        if (psType != 1 || enabled) logger(message())
    }
}
