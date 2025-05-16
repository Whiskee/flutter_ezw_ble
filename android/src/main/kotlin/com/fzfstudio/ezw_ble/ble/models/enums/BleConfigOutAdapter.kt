package com.fzfstudio.ezw_ble.ble.models.enums

import com.google.gson.JsonElement
import com.google.gson.JsonPrimitive
import com.google.gson.JsonSerializationContext
import com.google.gson.JsonSerializer
import java.lang.reflect.Type

class BleConfigOutAdapter: JsonSerializer<BleConnectState> {
    override fun serialize(
        src: BleConnectState?,
        typeOfSrc: Type?,
        context: JsonSerializationContext?
    ): JsonElement? = JsonPrimitive(src?.name)
}