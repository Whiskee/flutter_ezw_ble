package com.fzfstudio.ezw_ble.ble

/** Android 单槽位 GATT 写回调应由哪条本地发送路径认领。 */
internal enum class BleGattWriteCallbackOwner {
    OTA,
    FILE,
    NORMAL,
    NONE,
}

/**
 * 统一普通命令、OTA 批次与文件批次写回调的归属规则。
 *
 * 已提交的批次写（含取消后的 drain barrier）优先认领本通道/未知类型 callback；否则才按普通
 * 队列 head 的 psType 匹配。普通队列在批次占槽时不会写出，因此这里的顺序不会漏判：文件控制包
 * 与文件 RAW 批次都是 psType=3，只有批次真正占着物理槽时才允许它抢先认领。
 */
internal object BleGattWriteCallbackOwnerPolicy {
    fun resolve(
        psType: Int?,
        otaHasOutstandingWrite: Boolean,
        normalHeadPsType: Int?,
        fileHasOutstandingWrite: Boolean = false,
    ): BleGattWriteCallbackOwner {
        if (otaHasOutstandingWrite && (psType == null || psType == BlePsType.OTA)) {
            return BleGattWriteCallbackOwner.OTA
        }
        if (fileHasOutstandingWrite && (psType == null || psType == BlePsType.FILE)) {
            return BleGattWriteCallbackOwner.FILE
        }
        if (normalHeadPsType != null && (psType == null || normalHeadPsType == psType)) {
            return BleGattWriteCallbackOwner.NORMAL
        }
        return BleGattWriteCallbackOwner.NONE
    }
}

/** 与 Dart `BleG2PsType` 对齐的私有服务类型；批量写入口只放行各自的通道。 */
internal object BlePsType {
    const val OTA = 1
    const val FILE = 3
}
