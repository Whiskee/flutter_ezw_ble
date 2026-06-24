package com.fzfstudio.ezw_ble.ble.models

import android.util.Base64

/**
 * 原生 GATT 指令发送结果。
 *
 * 该模型通过 EventChannel 回传给 Dart；二进制 payload 必须保持 Base64 编码，避免
 * Flutter 标准通道在不同平台间传输 ByteArray 时出现类型不一致。
 */
data class BleCmd(
    /** 指令所属设备的 Android address / 插件 uuid。 */
    val uuid: String,
    /** 私有服务类型，用于区分默认/OTA/stream/file 等写入通道。 */
    val psType: Int,
    /** 设备返回或失败占位的原始二进制数据。 */
    val data: ByteArray?,
    /** 原生写入或读取是否成功。 */
    val isSuccess: Boolean,
) {

    companion object {
        /**
         * 构造发送失败事件。
         *
         * 失败事件不携带 payload，Dart 侧只需要 uuid/psType/isSuccess 判断对应通道失败。
         */
        fun fail(uuid: String, psType: Int): BleCmd = BleCmd(uuid, psType, null, false)
    }

    /**
     * 转换为 Flutter EventChannel 可传输的 Map。
     *
     * ByteArray 统一编码为无换行 Base64，保持 Android/iOS/Dart 三端事件格式一致。
     */
    fun toFlutterMap(): Map<String, Any?> = mapOf(
        // 1. uuid/psType/isSuccess 直接透传给 Dart 侧模型。
        "uuid" to uuid,
        "psType" to psType,
        // 2. MethodChannel/EventChannel 不直接暴露 ByteArray 语义，统一使用 Base64 字符串。
        "data" to data?.let { Base64.encodeToString(it, Base64.NO_WRAP) },
        "isSuccess" to isSuccess,
    )

    /**
     * 比较两个指令结果是否等价。
     *
     * ByteArray 默认按引用比较，这里必须使用 contentEquals 才能让测试和队列判断按内容生效。
     */
    override fun equals(other: Any?): Boolean {
        // 1. 同一对象必然相等。
        if (this === other) return true

        // 2. 不同模型类型不能继续比较字段。
        if (javaClass != other?.javaClass) return false
        other as BleCmd

        // 3. 标量字段先比较，失败时快速返回。
        if (uuid != other.uuid) return false
        if (psType != other.psType) return false

        // 4. ByteArray 要按内容比较，避免相同 payload 因引用不同被误判。
        if (data != null) {
            if (other.data == null) return false
            if (!data.contentEquals(other.data)) return false
        } else if (other.data != null) return false
        if (isSuccess != other.isSuccess) return false

        return true
    }

    /**
     * 生成与 `equals` 一致的 hashCode。
     *
     * ByteArray 必须使用 contentHashCode，与 contentEquals 保持集合语义一致。
     */
    override fun hashCode(): Int {
        // 1. 按 data class 默认字段顺序组合 hash，便于定位变更影响。
        var result = uuid.hashCode()
        result = 31 * result + psType
        result = 31 * result + (data?.contentHashCode() ?: 0)
        result = 31 * result + isSuccess.hashCode()
        return result
    }

}
