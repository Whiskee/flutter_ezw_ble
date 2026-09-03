package com.fzfstudio.ezw_ble.ble

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BleAndroidSecurityGateAttemptRegistryTest {
    private val characteristic = UUID.fromString("00005403-0000-1000-8000-00805f9b34fb")

    @Test
    fun `one exact owner submits gate once and consumes matching callback`() {
        val registry = BleAndroidSecurityGateAttemptRegistry()
        val owner = owner(gatt = Any(), attempt = 7L)

        assertTrue(registry.start(owner, characteristic))
        assertFalse(registry.start(owner, characteristic))
        assertNotNull(registry.consume(owner, characteristic))
        assertNull(registry.consume(owner, characteristic))

        registry.markPassed(owner)
        assertTrue(registry.hasPassed(owner))
        assertFalse(registry.start(owner, characteristic))
    }

    @Test
    fun `stale gatt and generation cannot consume next attempt`() {
        val registry = BleAndroidSecurityGateAttemptRegistry()
        val oldGatt = Any()
        val old = owner(gatt = oldGatt, attempt = 2L)
        val newGatt = Any()
        val next = owner(gatt = newGatt, attempt = 3L)

        assertTrue(registry.start(old, characteristic))
        assertNull(registry.consume(owner(gatt = Any(), attempt = 2L), characteristic))
        assertNull(registry.consume(next, characteristic))

        registry.cancelEndpoint(old.endpointId)
        assertTrue(registry.start(next, characteristic))
        assertNull(registry.consume(old, characteristic))
        assertNotNull(registry.consume(next, characteristic))
    }

    private fun owner(gatt: Any, attempt: Long) = BleAndroidSecurityGateOwner(
        endpointId = "AA:BB:CC:DD:EE:FF",
        sessionGeneration = 11L,
        attemptGeneration = attempt,
        sessionId = attempt,
        gattIdentity = gatt,
    )
}
