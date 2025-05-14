package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.ByteArrayAdapter
import com.fzfstudio.ezw_utils.gson.GsonSerializable
import com.google.gson.annotations.JsonAdapter

data class BleCmd(
    val uuid: String,
    //  Private Service 类型
    val psType: Int,
    @JsonAdapter(ByteArrayAdapter::class)
    val data: ByteArray?,
    val isSuccess: Boolean,
): GsonSerializable() {

    companion object {
        fun fail(uuid: String, psType: Int): BleCmd = BleCmd(uuid, psType, null, false)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as BleCmd
        if (uuid != other.uuid) return false
        if (psType != other.psType) return false
        if (data != null) {
            if (other.data == null) return false
            if (!data.contentEquals(other.data)) return false
        } else if (other.data != null) return false
        if (isSuccess != other.isSuccess) return false

        return true
    }

    override fun hashCode(): Int {
        var result = uuid.hashCode()
        result = 31 * result + psType
        result = 31 * result + (data?.contentHashCode() ?: 0)
        result = 31 * result + isSuccess.hashCode()
        return result
    }

}