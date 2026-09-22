package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals

/** Locks Android MethodChannel routing at numeric acronym boundaries such as `G2Ota`. */
class BleMethodChannelNameResolutionTest {

    @Test
    fun `G2 OTA transaction methods resolve across the numeric acronym boundary`() {
        val expectedMethods = mapOf(
            "beginG2OtaTransaction" to BleMC.BEGIN_G2_OTA_TRANSACTION,
            "updateG2OtaEndpoint" to BleMC.UPDATE_G2_OTA_ENDPOINT,
            "finishG2OtaTransaction" to BleMC.FINISH_G2_OTA_TRANSACTION,
            "queryG2OtaTransaction" to BleMC.QUERY_G2_OTA_TRANSACTION,
        )

        expectedMethods.forEach { (method, expected) ->
            assertEquals(expected, BleMC.from(method), method)
        }
    }

    @Test
    fun `legacy camel case routing and unknown fallback remain unchanged`() {
        assertEquals(BleMC.GET_PLATFORM_VERSION, BleMC.from("getPlatformVersion"))
        assertEquals(BleMC.UNKNOWN, BleMC.from("missingMethod"))
    }
}
