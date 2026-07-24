package com.fzfstudio.ezw_ble.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class BleReconnectSessionUpdatePolicyTest {
    @Test
    fun `same or lower session keeps current physical owner`() {
        assertEquals(
            BleReconnectSessionUpdateAction.KEEP_CURRENT,
            BleReconnectSessionUpdatePolicy.resolve(
                currentSessionGeneration = 13L,
                incomingSessionGeneration = 13L,
                hasPhysicalOwner = true,
            ),
        )
        assertEquals(
            BleReconnectSessionUpdateAction.KEEP_CURRENT,
            BleReconnectSessionUpdatePolicy.resolve(
                currentSessionGeneration = 13L,
                incomingSessionGeneration = 2L,
                hasPhysicalOwner = true,
            ),
        )
    }

    @Test
    fun `higher session without GATT only advances task metadata`() {
        assertEquals(
            BleReconnectSessionUpdateAction.UPDATE_TASK,
            BleReconnectSessionUpdatePolicy.resolve(
                currentSessionGeneration = 2L,
                incomingSessionGeneration = 13L,
                hasPhysicalOwner = false,
            ),
        )
    }

    @Test
    fun `higher session with GATT requires exact owner rebuild`() {
        assertEquals(
            BleReconnectSessionUpdateAction.REBUILD_PHYSICAL_OWNER,
            BleReconnectSessionUpdatePolicy.resolve(
                currentSessionGeneration = 2L,
                incomingSessionGeneration = 13L,
                hasPhysicalOwner = true,
            ),
        )
    }
}
