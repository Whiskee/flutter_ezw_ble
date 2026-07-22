package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 全局连接 Gate 的纯状态机测试，不依赖 Android BluetoothGatt。 */
class BleConnectionAdmissionGateTest {

    @Test
    fun `admission keeps native attempt generation separate from Dart session generation`() {
        val admission = BleConnectionAdmission(
            endpointId = "g2-left",
            generation = 7,
            sessionId = 11,
            source = BleConnectSource.AUTO_RECONNECT,
            sessionGeneration = 42,
        )

        assertEquals(7, admission.generation)
        assertEquals(42, admission.sessionGeneration)
    }

    @Test
    fun `automatic callbacks keep fifo while manual waiting nodes jump the queue`() {
        val gate = BleConnectionAdmissionGate()
        val first = admission("auto-1", 1, 11, BleConnectSource.AUTO_RECONNECT)
        val second = admission("auto-2", 1, 12, BleConnectSource.AUTO_RECONNECT)
        val manual = admission("manual", 1, 13, BleConnectSource.MANUAL_RECONNECT)

        listOf(first, second, manual).forEach { gate.registerAttempt(it.endpointId, it.generation) }

        assertEquals(BleConnectionAdmissionDecision.GRANTED, gate.onPhysicalConnected(first))
        assertEquals(BleConnectionAdmissionDecision.QUEUED, gate.onPhysicalConnected(second))
        assertEquals(BleConnectionAdmissionDecision.QUEUED, gate.onPhysicalConnected(manual))
        assertEquals(manual, gate.complete(first.endpointId, first.generation, first.sessionId))
        assertEquals(second, gate.complete(manual.endpointId, manual.generation, manual.sessionId))
        assertNull(gate.complete(second.endpointId, second.generation, second.sessionId))
    }

    @Test
    fun `new generation rejects stale and duplicate physical callbacks`() {
        val gate = BleConnectionAdmissionGate()
        val current = admission("g2-left", 2, 21, BleConnectSource.AUTO_RECONNECT)
        gate.registerAttempt(current.endpointId, current.generation)

        assertEquals(
            BleConnectionAdmissionDecision.STALE,
            gate.onPhysicalConnected(current.copy(generation = 1, sessionId = 20)),
        )
        assertEquals(BleConnectionAdmissionDecision.GRANTED, gate.onPhysicalConnected(current))
        assertEquals(BleConnectionAdmissionDecision.DUPLICATE, gate.onPhysicalConnected(current))
    }

    @Test
    fun `blank endpoint identity fails closed`() {
        val gate = BleConnectionAdmissionGate()
        val blank = admission("   ", 1, 22, BleConnectSource.AUTO_RECONNECT)
        gate.registerAttempt(blank.endpointId, blank.generation)

        assertEquals(
            BleConnectionAdmissionDecision.INVALID_IDENTITY,
            gate.onPhysicalConnected(blank),
        )
        assertNull(gate.cancelEndpoint(blank.endpointId))
    }

    @Test
    fun `clean reset invalidates active waiting and prephysical callbacks`() {
        val gate = BleConnectionAdmissionGate()
        val active = admission("active", 1, 51, BleConnectSource.AUTO_RECONNECT)
        val waiting = admission("waiting", 1, 52, BleConnectSource.AUTO_RECONNECT)
        val prephysical = admission("prephysical", 1, 53, BleConnectSource.AUTO_RECONNECT)
        listOf(active, waiting, prephysical).forEach {
            gate.registerAttempt(it.endpointId, it.generation)
        }

        assertEquals(BleConnectionAdmissionDecision.GRANTED, gate.onPhysicalConnected(active))
        assertEquals(BleConnectionAdmissionDecision.QUEUED, gate.onPhysicalConnected(waiting))

        gate.invalidateAllAndReset()

        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(active))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(waiting))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(prephysical))

        val fresh = admission("active", 2, 54, BleConnectSource.MANUAL_RECONNECT)
        gate.registerAttempt(fresh.endpointId, fresh.generation)
        assertEquals(BleConnectionAdmissionDecision.GRANTED, gate.onPhysicalConnected(fresh))
    }

    @Test
    fun `config revocation removes active waiting and prephysical as one batch`() {
        val gate = BleConnectionAdmissionGate()
        val revokedActive = admission("revoked-active", 1, 61, BleConnectSource.AUTO_RECONNECT)
        val revokedWaiting = admission("revoked-waiting", 1, 62, BleConnectSource.AUTO_RECONNECT)
        val validWaiting = admission("valid", 1, 63, BleConnectSource.AUTO_RECONNECT)
        val revokedPrephysical = admission("revoked-prephysical", 1, 64, BleConnectSource.AUTO_RECONNECT)
        listOf(revokedActive, revokedWaiting, validWaiting, revokedPrephysical).forEach {
            gate.registerAttempt(it.endpointId, it.generation)
        }
        gate.onPhysicalConnected(revokedActive)
        gate.onPhysicalConnected(revokedWaiting)
        gate.onPhysicalConnected(validWaiting)

        val next = gate.cancelEndpoints(
            setOf(
                revokedActive.endpointId,
                revokedWaiting.endpointId,
                revokedPrephysical.endpointId,
            ),
        )

        assertEquals(validWaiting, next)
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(revokedActive))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(revokedWaiting))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(revokedPrephysical))
    }

    @Test
    fun `cancel active grants next and bluetooth off resets every owner`() {
        val gate = BleConnectionAdmissionGate()
        val first = admission("ring", 1, 31, BleConnectSource.AUTO_RECONNECT)
        val second = admission("g2-right", 1, 32, BleConnectSource.AUTO_RECONNECT)
        listOf(first, second).forEach { gate.registerAttempt(it.endpointId, it.generation) }
        gate.onPhysicalConnected(first)
        gate.onPhysicalConnected(second)

        assertEquals(second, gate.cancelEndpoint(first.endpointId))
        gate.suspendAndReset()
        assertEquals(
            BleConnectionAdmissionDecision.SUSPENDED,
            gate.onPhysicalConnected(second.copy(generation = 2, sessionId = 33)),
        )

        gate.resume()
        gate.registerAttempt(second.endpointId, 3)
        assertEquals(
            BleConnectionAdmissionDecision.GRANTED,
            gate.onPhysicalConnected(second.copy(generation = 3, sessionId = 34)),
        )
    }

    @Test
    fun `manual promotion moves an automatic waiting node before automatic peers`() {
        val gate = BleConnectionAdmissionGate()
        val active = admission("active", 1, 41, BleConnectSource.AUTO_RECONNECT)
        val promoted = admission("promoted", 1, 42, BleConnectSource.AUTO_RECONNECT)
        val peer = admission("peer", 1, 43, BleConnectSource.AUTO_RECONNECT)
        listOf(active, promoted, peer).forEach { gate.registerAttempt(it.endpointId, it.generation) }
        gate.onPhysicalConnected(active)
        gate.onPhysicalConnected(promoted)
        gate.onPhysicalConnected(peer)

        gate.promote(promoted.endpointId, promoted.generation, promoted.sessionId)

        assertEquals(
            promoted.copy(source = BleConnectSource.MANUAL_RECONNECT),
            gate.complete(active.endpointId, active.generation, active.sessionId),
        )
    }

    @Test
    fun `lost active context releases exact session without cancelling newer generation`() {
        val gate = BleConnectionAdmissionGate()
        val lost = admission("ring", 1, 51, BleConnectSource.AUTO_RECONNECT)
        val peer = admission("g2-left", 1, 52, BleConnectSource.AUTO_RECONNECT)
        gate.registerAttempt(lost.endpointId, lost.generation)
        gate.registerAttempt(peer.endpointId, peer.generation)
        gate.onPhysicalConnected(lost)
        gate.onPhysicalConnected(peer)

        assertEquals(peer, gate.cancelSession(lost.endpointId, lost.generation, lost.sessionId))

        gate.registerAttempt(lost.endpointId, 2)
        val replacement = lost.copy(generation = 2, sessionId = 53)
        assertEquals(BleConnectionAdmissionDecision.QUEUED, gate.onPhysicalConnected(replacement))
        assertEquals(replacement, gate.complete(peer.endpointId, peer.generation, peer.sessionId))
    }

    @Test
    fun `only exact active admission owns the granted pipeline`() {
        val gate = BleConnectionAdmissionGate()
        val active = admission("ring", 3, 71, BleConnectSource.AUTO_RECONNECT)
        val queued = admission("g2-left", 4, 72, BleConnectSource.AUTO_RECONNECT)
        listOf(active, queued).forEach { gate.registerAttempt(it.endpointId, it.generation) }

        gate.onPhysicalConnected(active)
        gate.onPhysicalConnected(queued)

        assertTrue(gate.isActive(active))
        assertFalse(gate.isActive(active.copy(sessionId = 73)))
        assertFalse(gate.isActive(queued))
        assertEquals(queued, gate.complete(active.endpointId, active.generation, active.sessionId))
        assertTrue(gate.isActive(queued))
    }

    private fun admission(
        endpointId: String,
        generation: Long,
        sessionId: Long,
        source: BleConnectSource,
    ) = BleConnectionAdmission(endpointId, generation, sessionId, source)
}
