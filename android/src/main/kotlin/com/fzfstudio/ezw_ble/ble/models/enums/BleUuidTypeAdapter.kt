package com.fzfstudio.ezw_ble.ble.models.enums

import com.fzfstudio.ezw_utils.extension.toCamelCase
import com.fzfstudio.ezw_utils.extension.toUpperSnakeCase
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.google.gson.JsonDeserializationContext
import com.google.gson.JsonDeserializer
import com.google.gson.JsonElement
import com.google.gson.JsonPrimitive
import com.google.gson.JsonSerializationContext
import com.google.gson.JsonSerializer
import com.google.gson.annotations.JsonAdapter
import java.lang.reflect.Type

class BleUuidTypeAdapter: JsonSerializer<BleUuidType>, JsonDeserializer<BleUuidType> {
    override fun serialize(
        src: BleUuidType?,
        typeOfSrc: Type?,
        context: JsonSerializationContext?
    ): JsonElement? = JsonPrimitive(src?.name?.toCamelCase())

    override fun deserialize(
        json: JsonElement?,
        typeOfT: Type?,
        context: JsonDeserializationContext?
    ): BleUuidType? = BleUuidType.valueOf(json?.asString?.toUpperSnakeCase() ?: BleUuidType.COMMON.name)
}