package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import kotlin.test.Test
import kotlin.test.assertEquals

class BleConnectSourceContractTest {
    @Test
    fun flutterDeviceWakeSourcesRemainDistinctInNativeAdmissions() {
        assertEquals(
            BleConnectSource.ANDROID_CDM,
            BleConnectSource.fromFlutterValue("androidCdm"),
        )
        assertEquals(
            BleConnectSource.ANDROID_BLE_PENDING_INTENT,
            BleConnectSource.fromFlutterValue("androidBlePendingIntent"),
        )
        assertEquals(true, BleConnectSource.ANDROID_CDM.isAutomaticReconnect)
        assertEquals(true, BleConnectSource.ANDROID_BLE_PENDING_INTENT.isAutomaticReconnect)
    }
}
