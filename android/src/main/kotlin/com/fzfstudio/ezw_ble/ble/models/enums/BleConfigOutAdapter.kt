package com.fzfstudio.ezw_ble.ble.models.enums

import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.google.gson.JsonElement
import com.google.gson.JsonPrimitive
import com.google.gson.JsonSerializationContext
import com.google.gson.JsonSerializer
import java.lang.reflect.Type

class BleConfigOutAdapter: JsonSerializer<BleConfig> {
    override fun serialize(
        src: BleConfig?,
        typeOfSrc: Type?,
        context: JsonSerializationContext?
    ): JsonElement? = JsonPrimitive(src?.name)
}