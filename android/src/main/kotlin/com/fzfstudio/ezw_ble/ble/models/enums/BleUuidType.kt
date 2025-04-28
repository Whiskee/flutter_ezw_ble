package com.fzfstudio.ezw_ble.ble.models.enums

import com.google.gson.annotations.JsonAdapter

@JsonAdapter(BleUuidTypeAdapter::class)
enum class BleUuidType {
    COMMON,
    LARGE_DATA,
    STREAMING,
    OTA;
}