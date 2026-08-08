package com.fzfstudio.ezw_ble.ble

/** Android 单槽位 GATT 写回调应由哪条本地发送路径认领。 */
internal enum class BleGattWriteCallbackOwner {
    OTA,
    NORMAL,
    NONE,
}

/**
 * 统一普通命令与 OTA 写回调的归属规则。
 *
 * OTA 已提交写（含取消后的 drain barrier）优先认领 RAW/未知类型 callback；否则才按普通
 * 队列 head 的 psType 匹配。这样旧 OTA callback 不会 poll 普通队列或完成新 OTA attempt。
 */
internal object BleGattWriteCallbackOwnerPolicy {
    fun resolve(
        psType: Int?,
        otaHasOutstandingWrite: Boolean,
        normalHeadPsType: Int?,
    ): BleGattWriteCallbackOwner {
        if (otaHasOutstandingWrite && (psType == null || psType == 1)) {
            return BleGattWriteCallbackOwner.OTA
        }
        if (normalHeadPsType != null && (psType == null || normalHeadPsType == psType)) {
            return BleGattWriteCallbackOwner.NORMAL
        }
        return BleGattWriteCallbackOwner.NONE
    }
}
