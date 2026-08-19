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

    @Test
    fun `submitted file batch owns the raw callback over a queued file control packet`() {
        // Both the file control queue and the RAW batch use psType=3. Only the batch actually
        // holds the physical slot here, so attributing this callback to the normal head would
        // complete a command that was never written.
        val owner = BleGattWriteCallbackOwnerPolicy.resolve(
            psType = 3,
            otaHasOutstandingWrite = false,
            normalHeadPsType = 3,
            fileHasOutstandingWrite = true,
        )

        assertEquals(BleGattWriteCallbackOwner.FILE, owner)
    }

    @Test
    fun `file batch does not claim the callback of an in-flight file control packet`() {
        // start-big-package is written through the normal queue and its callback can land while
        // the RAW batch is still backpressured. The batch must not steal it.
        val owner = BleGattWriteCallbackOwnerPolicy.resolve(
            psType = 3,
            otaHasOutstandingWrite = false,
            normalHeadPsType = 3,
            fileHasOutstandingWrite = false,
        )

        assertEquals(BleGattWriteCallbackOwner.NORMAL, owner)
    }

    @Test
    fun `ota keeps priority over file for an unknown characteristic callback`() {
        val owner = BleGattWriteCallbackOwnerPolicy.resolve(
            psType = null,
            otaHasOutstandingWrite = true,
            normalHeadPsType = null,
            fileHasOutstandingWrite = true,
        )

        assertEquals(BleGattWriteCallbackOwner.OTA, owner)
    }

    @Test
    fun `ota callback is never attributed to an outstanding file batch`() {
        val owner = BleGattWriteCallbackOwnerPolicy.resolve(
            psType = 1,
            otaHasOutstandingWrite = false,
            normalHeadPsType = null,
            fileHasOutstandingWrite = true,
        )

        assertEquals(BleGattWriteCallbackOwner.NONE, owner)
    }
}
