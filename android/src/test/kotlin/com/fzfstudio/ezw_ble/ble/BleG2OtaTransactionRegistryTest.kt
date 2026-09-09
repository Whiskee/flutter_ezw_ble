package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BleG2OtaTransactionRegistryTest {
    private val endpoints = listOf(
        BleG2OtaEndpointIdentity(
            uuid = "AA:BB:CC:DD:EE:01",
            name = "Even-L",
            sessionGeneration = 10,
            attemptGeneration = 11,
        ),
        BleG2OtaEndpointIdentity(
            uuid = "AA:BB:CC:DD:EE:02",
            name = "Even-R",
            sessionGeneration = 20,
            attemptGeneration = 21,
        ),
    )

    @Test
    fun `begin is idempotent for the same frozen scope and rejects conflicts`() {
        val registry = BleG2OtaTransactionRegistry()

        val first = registry.begin("tx-1", 3, "G2", "SN001", endpoints)
        val duplicate = registry.begin("tx-1", 3, "G2", "SN001", endpoints)
        val conflict = registry.begin("tx-1", 4, "G2", "SN001", endpoints)

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, first.status)
        assertEquals(first.instanceId, duplicate.instanceId)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, duplicate.status)
        assertEquals(BleG2OtaTransactionStatus.INVALID_REQUEST, conflict.status)
    }

    @Test
    fun `parked endpoint cannot be recovered and finish replays are side effect free`() {
        val registry = BleG2OtaTransactionRegistry()
        val begin = registry.begin("tx-2", 8, "G2", "SN002", endpoints)

        val park = registry.updateEndpoint(
            transactionId = "tx-2",
            generation = 8,
            instanceId = begin.instanceId,
            uuid = endpoints.first().uuid,
            action = BleG2OtaEndpointAction.PARK,
            sessionGeneration = 10,
            attemptGeneration = 11,
        )
        val recoverParked = registry.updateEndpoint(
            transactionId = "tx-2",
            generation = 8,
            instanceId = begin.instanceId,
            uuid = endpoints.first().uuid,
            action = BleG2OtaEndpointAction.RECOVER,
            sessionGeneration = 10,
            attemptGeneration = 11,
        )
        val prepare = registry.prepareFinish("tx-2", 8, begin.instanceId, "success", "G2", "SN002", endpoints)
        val finish = registry.commitFinish("tx-2", 8, begin.instanceId, "success", "G2", "SN002", endpoints)
        val replay = registry.commitFinish("tx-2", 8, begin.instanceId, "success", "G2", "SN002", endpoints)

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, park.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, recoverParked.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, prepare.status)
        assertEquals(BleG2OtaTransactionStatus.COMMITTED, finish.status)
        assertEquals(BleG2OtaTransactionStatus.ALREADY_COMMITTED, replay.status)
        assertTrue(finish.instanceId.isNotBlank())
    }

    @Test
    fun `recovered endpoint can finish with frozen transaction scope after physical rebind`() {
        val registry = BleG2OtaTransactionRegistry()
        val begin = registry.begin("tx-rebound-finish", 9, "G2", "SN-REBOUND", endpoints)
        val endpoint = endpoints.first()

        val recover = registry.updateEndpoint(
            "tx-rebound-finish",
            9,
            begin.instanceId,
            endpoint.uuid,
            BleG2OtaEndpointAction.RECOVER,
            endpoint.sessionGeneration,
            endpoint.attemptGeneration,
        )
        val bind = registry.updateEndpoint(
            "tx-rebound-finish",
            9,
            begin.instanceId,
            endpoint.uuid,
            BleG2OtaEndpointAction.BIND,
            30,
            31,
        )
        val oldPairCannotParkNewOwner = registry.updateEndpoint(
            "tx-rebound-finish",
            9,
            begin.instanceId,
            endpoint.uuid,
            BleG2OtaEndpointAction.PARK,
            endpoint.sessionGeneration,
            endpoint.attemptGeneration,
        )
        val park = registry.updateEndpoint(
            "tx-rebound-finish",
            9,
            begin.instanceId,
            endpoint.uuid,
            BleG2OtaEndpointAction.PARK,
            30,
            31,
        )
        val duplicateBegin = registry.begin("tx-rebound-finish", 9, "G2", "SN-REBOUND", endpoints)
        val invalidPairFinish = registry.prepareFinish(
            "tx-rebound-finish",
            9,
            begin.instanceId,
            "success",
            "G2",
            "SN-REBOUND",
            endpoints.mapIndexed { index, identity ->
                if (index == 0) identity.copy(sessionGeneration = 30, attemptGeneration = 0) else identity
            },
        )
        val conflictingEndpointFinish = registry.prepareFinish(
            "tx-rebound-finish",
            9,
            begin.instanceId,
            "success",
            "G2",
            "SN-REBOUND",
            endpoints.mapIndexed { index, identity ->
                if (index == 0) identity.copy(name = "Wrong-L") else identity
            },
        )
        val prepare = registry.prepareFinish(
            "tx-rebound-finish", 9, begin.instanceId, "success", "G2", "SN-REBOUND", endpoints,
        )
        val finish = registry.commitFinish(
            "tx-rebound-finish", 9, begin.instanceId, "success", "G2", "SN-REBOUND", endpoints,
        )
        val replay = registry.commitFinish(
            "tx-rebound-finish", 9, begin.instanceId, "success", "G2", "SN-REBOUND", endpoints,
        )

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, recover.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, bind.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, oldPairCannotParkNewOwner.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, park.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, duplicateBegin.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, invalidPairFinish.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, conflictingEndpointFinish.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, prepare.status)
        assertEquals(BleG2OtaTransactionStatus.COMMITTED, finish.status)
        assertEquals(BleG2OtaTransactionStatus.ALREADY_COMMITTED, replay.status)
    }

    @Test
    fun `active transactions reject overlapping endpoint ownership`() {
        val registry = BleG2OtaTransactionRegistry()

        val first = registry.begin("tx-3a", 1, "G2", "SN003", endpoints)
        val overlap = registry.begin("tx-3b", 2, "G2", "SN004", listOf(endpoints.first()))

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, first.status)
        assertEquals(BleG2OtaTransactionStatus.INVALID_REQUEST, overlap.status)
        assertEquals("endpointOverlap", overlap.reason)
    }

    @Test
    fun `terminal replay still validates owner scope and reports wrong owner as stale`() {
        val registry = BleG2OtaTransactionRegistry()
        val begin = registry.begin("tx-4", 5, "G2", "SN004", endpoints)
        val prepare = registry.prepareFinish("tx-4", 5, begin.instanceId, "success", "G2", "SN004", endpoints)
        val finish = registry.commitFinish("tx-4", 5, begin.instanceId, "success", "G2", "SN004", endpoints)
        val staleReplay = registry.commitFinish("tx-4", 5, "old-native", "success", "G2", "SN004", endpoints)
        val staleQuery = registry.query("tx-4", 5, "old-native")

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, prepare.status)
        assertEquals(BleG2OtaTransactionStatus.COMMITTED, finish.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, staleReplay.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, staleQuery.status)
        assertEquals("ownerMismatch", staleQuery.reason)
    }

    @Test
    fun `query distinguishes unknown token from previous native instance credential`() {
        val registry = BleG2OtaTransactionRegistry()

        val unknownSameProcess = registry.query("tx-missing", 9, "")
        val previousProcess = registry.query("tx-missing", 9, "old-native-instance")

        assertEquals(BleG2OtaTransactionStatus.UNKNOWN, unknownSameProcess.status)
        assertEquals(BleG2OtaTransactionStatus.INVALIDATED, previousProcess.status)
        assertEquals("nativeInstanceRecreated", previousProcess.reason)
    }

    @Test
    fun `cancel before begin tombstones the id and blocks late begin`() {
        val registry = BleG2OtaTransactionRegistry()

        val cancel = registry.prepareFinish("tx-5", 6, "", "cancelled", "G2", "SN005", endpoints)
        val lateBegin = registry.begin("tx-5", 6, "G2", "SN005", endpoints)

        assertEquals(BleG2OtaTransactionStatus.INVALIDATED, cancel.status)
        assertEquals(BleG2OtaTransactionStatus.INVALIDATED, lateBegin.status)
    }

    @Test
    fun `blank instance can cancel exact active transaction but cannot report success or failure`() {
        val registry = BleG2OtaTransactionRegistry()
        val successBegin = registry.begin("tx-5-success", 6, "G2", "SN005S", endpoints)
        val blankSuccess = registry.prepareFinish("tx-5-success", 6, "", "success", "G2", "SN005S", endpoints)
        registry.prepareFinish("tx-5-success", 6, successBegin.instanceId, "success", "G2", "SN005S", endpoints)
        registry.commitFinish("tx-5-success", 6, successBegin.instanceId, "success", "G2", "SN005S", endpoints)
        val failureBegin = registry.begin("tx-5-failed", 7, "G2", "SN005F", endpoints)
        val blankFailed = registry.prepareFinish("tx-5-failed", 7, "", "failed", "G2", "SN005F", endpoints)
        registry.prepareFinish("tx-5-failed", 7, failureBegin.instanceId, "failed", "G2", "SN005F", endpoints)
        registry.commitFinish("tx-5-failed", 7, failureBegin.instanceId, "failed", "G2", "SN005F", endpoints)
        val cancelBegin = registry.begin("tx-5-cancel", 8, "G2", "SN005C", endpoints)
        val blankCancelPrepare = registry.prepareFinish("tx-5-cancel", 8, "", "cancelled", "G2", "SN005C", endpoints)
        val blankCancelCommit = registry.commitFinish("tx-5-cancel", 8, "", "cancelled", "G2", "SN005C", endpoints)

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, successBegin.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, blankSuccess.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, failureBegin.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, blankFailed.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, cancelBegin.status)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, blankCancelPrepare.status)
        assertEquals(BleG2OtaTransactionStatus.COMMITTED, blankCancelCommit.status)
    }

    @Test
    fun `recover without a physical pair is only allowed for never bound waiting endpoints`() {
        val registry = BleG2OtaTransactionRegistry()
        val waiting = listOf(BleG2OtaEndpointIdentity("AA:BB:CC:DD:EE:33", "Even-L"))
        val beginWaiting = registry.begin("tx-6a", 1, "G2", "SN006A", waiting)
        val recoverWaiting = registry.updateEndpoint(
            "tx-6a",
            1,
            beginWaiting.instanceId,
            waiting.first().uuid,
            BleG2OtaEndpointAction.RECOVER,
            0,
            0,
        )
        val beginBound = registry.begin("tx-6b", 2, "G2", "SN006B", endpoints)
        val recoverBoundZero = registry.updateEndpoint(
            "tx-6b",
            2,
            beginBound.instanceId,
            endpoints.first().uuid,
            BleG2OtaEndpointAction.RECOVER,
            0,
            0,
        )

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, recoverWaiting.status)
        assertEquals(BleG2OtaTransactionStatus.STALE_OWNER, recoverBoundZero.status)
    }

    @Test
    fun `active context is exposed only before prepared finish commits`() {
        val registry = BleG2OtaTransactionRegistry()
        val begin = registry.begin("tx-7", 7, "G2", "SN007", endpoints)

        val activeContext = registry.activeContextForEndpoint(endpoints.first().uuid)
        val prepare = registry.prepareFinish("tx-7", 7, begin.instanceId, "success", "G2", "SN007", endpoints)
        val retiringContext = registry.activeContextForEndpoint(endpoints.first().uuid)
        val commit = registry.commitFinish("tx-7", 7, begin.instanceId, "success", "G2", "SN007", endpoints)
        val retiredContext = registry.activeContextForEndpoint(endpoints.first().uuid)

        assertEquals("tx-7", activeContext?.transactionId)
        assertEquals(begin.instanceId, activeContext?.instanceId)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, prepare.status)
        assertEquals("tx-7", retiringContext?.transactionId)
        assertEquals(BleG2OtaTransactionStatus.COMMITTED, commit.status)
        assertEquals(null, retiredContext)
    }

    @Test
    fun `recovery activation is exact and only allowed while endpoint is recovering`() {
        val registry = BleG2OtaTransactionRegistry()
        val begin = registry.begin("tx-8", 8, "G2", "SN008", endpoints)
        val bind = registry.updateEndpoint(
            "tx-8",
            8,
            begin.instanceId,
            endpoints.first().uuid,
            BleG2OtaEndpointAction.BIND,
            10,
            11,
        )
        val activeRecovery = registry.acceptsRecoveryContext("tx-8", 8, begin.instanceId, endpoints.first().uuid)
        val context = BleG2OtaNativeContext("tx-8", 8, begin.instanceId)
        val activePhysicalRecovery = registry.acceptsRecoveryPhysicalPair(
            context,
            endpoints.first().uuid,
            sessionGeneration = 10,
            attemptGeneration = 11,
        )
        val recover = registry.updateEndpoint(
            "tx-8",
            8,
            begin.instanceId,
            endpoints.first().uuid,
            BleG2OtaEndpointAction.RECOVER,
            10,
            11,
        )
        val recoveringRecovery = registry.acceptsRecoveryContext("tx-8", 8, begin.instanceId, endpoints.first().uuid)
        val exactPhysicalRecovery = registry.acceptsRecoveryPhysicalPair(
            context,
            endpoints.first().uuid,
            sessionGeneration = 10,
            attemptGeneration = 11,
        )
        val stalePhysicalRecovery = registry.acceptsRecoveryPhysicalPair(
            context,
            endpoints.first().uuid,
            sessionGeneration = 10,
            attemptGeneration = 12,
        )
        val zeroPhysicalRecovery = registry.acceptsRecoveryPhysicalPair(
            context,
            endpoints.first().uuid,
            sessionGeneration = 0,
            attemptGeneration = 0,
        )
        val staleInstanceRecovery = registry.acceptsRecoveryPhysicalPair(
            context.copy(instanceId = "stale-native-instance"),
            endpoints.first().uuid,
            sessionGeneration = 10,
            attemptGeneration = 11,
        )
        val park = registry.updateEndpoint(
            "tx-8",
            8,
            begin.instanceId,
            endpoints.first().uuid,
            BleG2OtaEndpointAction.PARK,
            10,
            11,
        )

        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, bind.status)
        assertFalse(activeRecovery)
        assertFalse(activePhysicalRecovery)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, recover.status)
        assertTrue(recoveringRecovery)
        assertTrue(exactPhysicalRecovery)
        assertFalse(stalePhysicalRecovery)
        assertFalse(zeroPhysicalRecovery)
        assertFalse(staleInstanceRecovery)
        assertEquals(BleG2OtaTransactionStatus.ACCEPTED, park.status)
        assertFalse(registry.acceptsContext("tx-8", 8, begin.instanceId, endpoints.first().uuid))
        assertFalse(registry.acceptsRecoveryContext("tx-8", 8, begin.instanceId, endpoints.first().uuid))
        assertFalse(registry.acceptsRecoveryPhysicalPair(context, endpoints.first().uuid, 10, 11))
    }
}
