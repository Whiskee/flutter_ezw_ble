package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals

class BleGattWriteCallbackOwnerPolicyTest {

    @Test
    fun `cancelled ota slot owns stale raw callback before a queued normal write`() {
        val owner = BleGattWriteCallbackOwnerPolicy.resolve(
            psType = 1,
            otaHasOutstandingWrite = true,
            normalHeadPsType = 1,
        )

        assertEquals(BleGattWriteCallbackOwner.OTA, owner)
    }

    @Test
    fun `outstanding ota slot owns callback when characteristic type is unavailable`() {
        val owner = BleGattWriteCallbackOwnerPolicy.resolve(
            psType = null,
            otaHasOutstandingWrite = true,
            normalHeadPsType = 0,
        )

        assertEquals(BleGattWriteCallbackOwner.OTA, owner)
    }

    @Test
    fun `normal head owns matching callback when ota has no outstanding write`() {
        val owner = BleGattWriteCallbackOwnerPolicy.resolve(
            psType = 0,
            otaHasOutstandingWrite = false,
            normalHeadPsType = 0,
        )

        assertEquals(BleGattWriteCallbackOwner.NORMAL, owner)
    }
}
