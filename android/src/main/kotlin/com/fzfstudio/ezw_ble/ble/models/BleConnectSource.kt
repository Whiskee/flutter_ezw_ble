package com.fzfstudio.ezw_ble.ble.models

import com.google.gson.annotations.SerializedName

/** 与 Dart `BleConnectSource` raw value 一致的原生连接来源。 */
enum class BleConnectSource(val flutterValue: String) {
    @SerializedName("unknown")
    UNKNOWN("unknown"),
    @SerializedName("autoReconnect")
    AUTO_RECONNECT("autoReconnect"),
    @SerializedName("androidCdm")
    ANDROID_CDM("androidCdm"),
    @SerializedName("androidBlePendingIntent")
    ANDROID_BLE_PENDING_INTENT("androidBlePendingIntent"),
    @SerializedName("manualReconnect")
    MANUAL_RECONNECT("manualReconnect"),
    @SerializedName("stateRestoration")
    STATE_RESTORATION("stateRestoration"),
    @SerializedName("foreground")
    FOREGROUND("foreground");

    val isAutomaticReconnect: Boolean
        get() = this == AUTO_RECONNECT ||
            this == ANDROID_CDM ||
            this == ANDROID_BLE_PENDING_INTENT ||
            this == STATE_RESTORATION

    companion object {
        /** 未知未来值必须降级为 UNKNOWN，保证跨版本 EventChannel 兼容。 */
        fun fromFlutterValue(value: String?): BleConnectSource =
            entries.firstOrNull { it.flutterValue == value } ?: UNKNOWN
    }
}
