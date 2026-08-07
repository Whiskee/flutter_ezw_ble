package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals

class BleOtaWriteErrorTest {

    @Test
    fun unavailableErrorMatchesSharedMethodChannelContract() {
        val error = BleOtaWriteError.unavailable(
            endpoint = "g2-left",
            reason = "writeCharacteristic returned false",
        )

        assertEquals("ota_write_unavailable", error.code)
        assertEquals("writeCharacteristic returned false", error.reason)
        assertEquals("g2-left", error.details["endpoint"])
        assertEquals("writeCharacteristic returned false", error.details["reason"])
        assertEquals(0, error.details["pending"])
    }

    @Test
    fun unsupportedErrorMatchesSharedMethodChannelContract() {
        val error = BleOtaWriteError.unsupported(
            endpoint = "g2-left",
            reason = "missing writeWithoutResponse",
        )

        assertEquals("ota_write_unsupported", error.code)
        assertEquals("missing writeWithoutResponse", error.reason)
        assertEquals("g2-left", error.details["endpoint"])
        assertEquals("missing writeWithoutResponse", error.details["reason"])
        assertEquals(0, error.details["pending"])
    }
}
