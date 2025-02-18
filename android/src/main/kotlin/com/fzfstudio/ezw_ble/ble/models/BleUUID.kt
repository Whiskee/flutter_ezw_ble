package com.fzfstudio.ezw_ble.ble.models

import java.io.Serializable
import java.util.UUID

data class BleUUID(
    val service: String,
    val writeChars: String? = null,
    val readChars: String? = null,
): Serializable {

    val serviceUUID: UUID
        get() = UUID.fromString(service)
    val writeCharsUUID: UUID?
        get() = if (writeChars == null) null else UUID.fromString(writeChars)
    val readCharsUUID: UUID?
        get() = if (readChars == null) null else UUID.fromString(readChars)

}