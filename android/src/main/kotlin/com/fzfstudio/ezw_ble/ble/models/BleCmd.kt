package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable
import com.fzfstudio.ezw_utils.gson.ByteArrayAdapter
import com.google.gson.annotations.JsonAdapter

data class BleCmd(
    val uuid: String,
    @JsonAdapter(ByteArrayAdapter::class)
    val data: ByteArray?,
    val isSuccess: Boolean,
): GsonSerializable() {

    companion object {
        fun fail(uuid: String): BleCmd = BleCmd(uuid, null, false)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as BleCmd
        if (isSuccess != other.isSuccess) return false
        if (uuid != other.uuid) return false
        if (!data.contentEquals(other.data)) return false
        return true
    }

    override fun hashCode(): Int {
        var result = isSuccess.hashCode()
        result = 31 * result + uuid.hashCode()
        result = 31 * result + (data?.contentHashCode() ?: 0)
        return result
    }

}