package com.fzfstudio.ezw_ble.ble.models

import java.io.Serializable
import java.util.UUID

/**
 * Android GATT 安全门禁配置。
 *
 * 固件把 [writeChars] 设为需要加密/认证的特征。一次有响应写既会触发系统安全建立，
 * 也能验证当前系统 Bond/LTK 是否真的可用；它必须早于普通业务 Notify。
 */
data class BleSecurityGate(
    /** 门禁特征所属服务 UUID。 */
    val service: String,
    /** 门禁写特征 UUID。 */
    val writeChars: String,
) : Serializable {
    val serviceUUID: UUID
        get() = UUID.fromString(service)

    val writeCharsUUID: UUID
        get() = UUID.fromString(writeChars)
}
