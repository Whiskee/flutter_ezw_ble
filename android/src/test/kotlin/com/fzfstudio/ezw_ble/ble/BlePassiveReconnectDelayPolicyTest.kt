package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals

/** 长离线只降低 zombie GATT 的重建频率，目标可见仍可快速唤醒。 */
class BlePassiveReconnectDelayPolicyTest {
    @Test
    fun `pre physical deadline failures use bounded adaptive backoff`() {
        assertEquals(1500L, BlePassiveReconnectDelayPolicy.delayAfterConsecutivePrePhysicalTimeouts(1))
        assertEquals(1500L, BlePassiveReconnectDelayPolicy.delayAfterConsecutivePrePhysicalTimeouts(3))
        assertEquals(5000L, BlePassiveReconnectDelayPolicy.delayAfterConsecutivePrePhysicalTimeouts(4))
        assertEquals(5000L, BlePassiveReconnectDelayPolicy.delayAfterConsecutivePrePhysicalTimeouts(10))
        assertEquals(30000L, BlePassiveReconnectDelayPolicy.delayAfterConsecutivePrePhysicalTimeouts(11))
    }

    @Test
    fun `target visible wake keeps a short debounce`() {
        assertEquals(250L, BlePassiveReconnectDelayPolicy.VISIBLE_WAKE_DEBOUNCE_MS)
    }
}
