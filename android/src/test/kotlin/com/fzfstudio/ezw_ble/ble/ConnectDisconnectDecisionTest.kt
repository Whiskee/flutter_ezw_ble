package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals

internal class ConnectDisconnectDecisionTest {
    @Test
    fun currentConnectingGattDisconnectMustBeHandled() {
        val decision = decideDisconnectDuringConnect(
            isConnecting = true,
            isCurrentGatt = true,
        )

        assertEquals(DisconnectDuringConnectDecision.HANDLE_DISCONNECT, decision)
    }

    @Test
    fun staleGattDisconnectCanBeIgnoredWhileNewGattIsConnecting() {
        val decision = decideDisconnectDuringConnect(
            isConnecting = true,
            isCurrentGatt = false,
        )

        assertEquals(DisconnectDuringConnectDecision.IGNORE_STALE_DISCONNECT, decision)
    }

    @Test
    fun nonConnectingCurrentGattDisconnectMustBeHandled() {
        val decision = decideDisconnectDuringConnect(
            isConnecting = false,
            isCurrentGatt = true,
        )

        assertEquals(DisconnectDuringConnectDecision.HANDLE_DISCONNECT, decision)
    }

    @Test
    fun nonConnectingStaleGattDisconnectMustStillBeHandled() {
        val decision = decideDisconnectDuringConnect(
            isConnecting = false,
            isCurrentGatt = false,
        )

        assertEquals(DisconnectDuringConnectDecision.HANDLE_DISCONNECT, decision)
    }

    @Test
    fun lmpTimeoutMustBeHandledWhenCurrentConnectIsStillConnecting() {
        val shouldIgnore = shouldIgnoreGattConnLmpTimeout(isConnecting = true)

        assertEquals(false, shouldIgnore)
    }

    @Test
    fun lmpTimeoutCanKeepLegacyIgnoreWhenNotInConnectingFlow() {
        val shouldIgnore = shouldIgnoreGattConnLmpTimeout(isConnecting = false)

        assertEquals(true, shouldIgnore)
    }
}
