package com.fzfstudio.ezw_ble.ble.models

import java.io.Serializable
import java.util.UUID

/// 蓝牙私有服务 （Private Service = PS）
data class BlePrivateService(
    //  服务本体
    val service: String,
    //  写特征
    val writeChars: String? = null,
    //  读特征
    val readChars: String? = null,
    //  服务所属类型：0 = 基础服务，1 = OTA，其他由用户自定义
    val type: Int = 0,
): Serializable {

    val serviceUUID: UUID
        get() = UUID.fromString(service)
    val writeCharsUUID: UUID?
        get() = if (writeChars == null) null else UUID.fromString(writeChars)
    val readCharsUUID: UUID?
        get() = if (readChars == null) null else UUID.fromString(readChars)

}