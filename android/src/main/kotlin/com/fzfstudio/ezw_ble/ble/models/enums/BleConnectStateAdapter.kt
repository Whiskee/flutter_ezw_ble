package com.fzfstudio.ezw_ble.ble.models.enums

import com.fzfstudio.ezw_utils.extension.toCamelCase
import com.fzfstudio.ezw_utils.extension.toUpperSnakeCase
import com.fzfstudio.ezw_ble.ble.models.BleConnectState
import com.google.gson.JsonDeserializationContext
import com.google.gson.JsonDeserializer
import com.google.gson.JsonElement
import com.google.gson.JsonPrimitive
import com.google.gson.JsonSerializationContext
import com.google.gson.JsonSerializer
import java.lang.reflect.Type

class BleConnectStateAdapter: JsonSerializer<BleConnectState>, JsonDeserializer<BleConnectState> {
    override fun serialize(
        src: BleConnectState?,
        typeOfSrc: Type?,
        context: JsonSerializationContext?
    ): JsonElement? = JsonPrimitive(src?.name?.toCamelCase())

    override fun deserialize(
        json: JsonElement?,
        typeOfT: Type?,
        context: JsonDeserializationContext?
    ): BleConnectState? = BleConnectState.valueOf(json?.asString?.toUpperSnakeCase() ?: BleConnectState.NONE.name)
}