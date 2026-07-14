package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlin.test.Test
import kotlin.test.assertEquals

class BlePostAdmissionTerminalPolicyTest {
    @Test
    fun `business connected exact gatt disconnect remains a live terminal`() {
        assertEquals(
            BlePostAdmissionTerminalDisposition.BUSINESS_CONNECTED_SESSION,
            BlePostAdmissionTerminalPolicy.resolve(
                state = BleConnectState.DISCONNECT_FROM_SYS,
                gattAndSessionStillOwnDevice = true,
                deviceIsBusinessConnected = true,
            ),
        )
    }

    @Test
    fun `stale gatt cannot terminate a newer business session`() {
        assertEquals(
            BlePostAdmissionTerminalDisposition.STALE,
            BlePostAdmissionTerminalPolicy.resolve(
                state = BleConnectState.DISCONNECT_FROM_SYS,
                gattAndSessionStillOwnDevice = false,
                deviceIsBusinessConnected = true,
            ),
        )
    }

    @Test
    fun `pipeline terminal without business connected stays stale after admission release`() {
        assertEquals(
            BlePostAdmissionTerminalDisposition.STALE,
            BlePostAdmissionTerminalPolicy.resolve(
                state = BleConnectState.TIMEOUT,
                gattAndSessionStillOwnDevice = true,
                deviceIsBusinessConnected = false,
            ),
        )
    }
}
