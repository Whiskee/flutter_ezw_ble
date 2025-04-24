package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_ble.ble.models.enums.BleUuidType
import java.io.Serializable
import java.util.UUID

data class BleUuid(
    val service: String,
    val writeChars: String? = null,
    val readChars: String? = null,
    val type: BleUuidType = BleUuidType.COMMON
): Serializable {

    val serviceUUID: UUID
        get() = UUID.fromString(service)
    val writeCharsUUID: UUID?
        get() = if (writeChars == null) null else UUID.fromString(writeChars)
    val readCharsUUID: UUID?
        get() = if (readChars == null) null else UUID.fromString(readChars)

}