package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BleBusinessConnectionAttemptTest {
    private val attemptA = BleBusinessConnectionAttempt("g2-left", 10, 1)
    private val attemptB = BleBusinessConnectionAttempt("g2-left", 10, 2)

    @Test
    fun `stale abort cannot remove replacement lease`() {
        val registry = BleBusinessConnectionLeaseRegistry()
        registry.prepare("g2-left", attemptA, 1)
        registry.prepare("g2-left", attemptB, 2)

        assertFalse(registry.abort("g2-left", attemptA))
        assertEquals(attemptB, registry.attempt("g2-left"))
        assertTrue(registry.abort("g2-left", attemptB))
        assertEquals(null, registry.attempt("g2-left"))
    }

    @Test
    fun `stale commit is rejected after admission moves to replacement attempt`() {
        assertEquals(
            BleBusinessConnectionStatus.ATTEMPT_MISMATCH,
            evaluate(attempt = attemptA, admission = attemptB, prepared = attemptB),
        )
    }

    @Test
    fun `commit rejects disconnected and incomplete gatt readiness`() {
        assertEquals(
            BleBusinessConnectionStatus.DEVICE_DISCONNECTED,
            evaluate(attempt = attemptA, isSystemConnected = false),
        )
        assertEquals(
            BleBusinessConnectionStatus.GATT_NOT_READY,
            evaluate(attempt = attemptA, isGattReady = false),
        )
    }

    @Test
    fun `accepted token is consumed so connected cannot publish twice`() {
        val registry = BleBusinessConnectionLeaseRegistry()
        registry.prepare("g2-left", attemptA, 1)

        assertEquals(
            BleBusinessConnectionStatus.ACCEPTED,
            evaluate(attempt = attemptA, prepared = registry.attempt("g2-left")),
        )
        registry.remove("g2-left")
        assertEquals(
            BleBusinessConnectionStatus.MISSING_PREPARE,
            evaluate(attempt = attemptA, prepared = registry.attempt("g2-left")),
        )
    }

    private fun evaluate(
        attempt: BleBusinessConnectionAttempt,
        admission: BleBusinessConnectionAttempt? = attempt,
        prepared: BleBusinessConnectionAttempt? = attempt,
        isSystemConnected: Boolean = true,
        isGattReady: Boolean = true,
    ): BleBusinessConnectionStatus = BleBusinessConnectionCommitPolicy.evaluate(
        attempt = attempt,
        admissionAttempt = admission,
        preparedAttempt = prepared,
        requirePrepare = true,
        hasGattSession = true,
        hasDevice = true,
        isSameGatt = true,
        isSystemConnected = isSystemConnected,
        isGattReady = isGattReady,
    )
}
