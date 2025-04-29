package com.fzfstudio.ezw_ble.ble.models.enums

import com.google.gson.annotations.JsonAdapter

@JsonAdapter(BleUuidTypeAdapter::class)
enum class BleUuidType {
    COMMON,
    LARGE_DATA,
    STREAMING,
    OTA;

    /// Get:
    val isCommon: Boolean
        get() = this == COMMON
    val isLargeData: Boolean
        get() = this == LARGE_DATA
    val isStreaming: Boolean
        get() = this == STREAMING
    val isOta: Boolean
        get() = this == OTA
}