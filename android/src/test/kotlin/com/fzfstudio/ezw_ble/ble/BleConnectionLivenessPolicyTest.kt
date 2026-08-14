package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals

class BleConnectionLivenessPolicyTest {
    @Test
    fun `native reconnecting replays one terminal when dart is stale connected`() {
        assertEquals(
            BleConnectionLivenessAction.REPLAY_TERMINAL,
            decide(nativeBusinessConnected = false),
        )
    }

    @Test
    fun `active connection attempt cannot be replayed as stale dart terminal`() {
        assertEquals(
            BleConnectionLivenessAction.NO_OP,
            decide(
                nativeBusinessConnected = false,
                connectionAttemptInProgress = true,
            ),
        )
    }

    @Test
    fun `missing gatt terminates stale native connected state`() {
        assertEquals(
            BleConnectionLivenessAction.TERMINATE_STALE_CONNECTED,
            decide(nativeBusinessConnected = true, hasExactGatt = false),
        )
    }

    @Test
    fun `explicit system disconnect terminates stale native connected state`() {
        assertEquals(
            BleConnectionLivenessAction.TERMINATE_STALE_CONNECTED,
            decide(
                nativeBusinessConnected = true,
                systemGattState = BleSystemGattConnectionState.DISCONNECTED,
            ),
        )
    }

    @Test
    fun `connected or unknown system state never forces teardown`() {
        assertEquals(
            BleConnectionLivenessAction.NO_OP,
            decide(
                nativeBusinessConnected = true,
                systemGattState = BleSystemGattConnectionState.CONNECTED,
            ),
        )
        assertEquals(
            BleConnectionLivenessAction.NO_OP,
            decide(
                nativeBusinessConnected = true,
                systemGattState = BleSystemGattConnectionState.UNKNOWN,
            ),
        )
    }

    @Test
    fun `missing owner epoch protected lifecycle and duplicate session fail closed`() {
        assertEquals(
            BleConnectionLivenessAction.NO_OP,
            decide(nativeBusinessConnected = false, hasPersistentReconnectOwner = false),
        )
        assertEquals(
            BleConnectionLivenessAction.NO_OP,
            decide(nativeBusinessConnected = false, hasEpochAcceptedAdmission = false),
        )
        assertEquals(
            BleConnectionLivenessAction.NO_OP,
            decide(nativeBusinessConnected = false, protectedByLifecycle = true),
        )
        assertEquals(
            BleConnectionLivenessAction.NO_OP,
            decide(nativeBusinessConnected = false, sessionAlreadyReconciled = true),
        )
    }

    private fun decide(
        nativeBusinessConnected: Boolean,
        hasExactGatt: Boolean = true,
        systemGattState: BleSystemGattConnectionState = BleSystemGattConnectionState.UNKNOWN,
        hasEpochAcceptedAdmission: Boolean = true,
        hasPersistentReconnectOwner: Boolean = true,
        protectedByLifecycle: Boolean = false,
        sessionAlreadyReconciled: Boolean = false,
        connectionAttemptInProgress: Boolean = false,
    ): BleConnectionLivenessAction = BleConnectionLivenessPolicy.decide(
        BleConnectionLivenessInput(
            dartClaimsConnected = true,
            nativeBusinessConnected = nativeBusinessConnected,
            hasExactGatt = hasExactGatt,
            systemGattState = systemGattState,
            hasEpochAcceptedAdmission = hasEpochAcceptedAdmission,
            hasPersistentReconnectOwner = hasPersistentReconnectOwner,
            protectedByLifecycle = protectedByLifecycle,
            sessionAlreadyReconciled = sessionAlreadyReconciled,
            connectionAttemptInProgress = connectionAttemptInProgress,
        ),
    )
}
