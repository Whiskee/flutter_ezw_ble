package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import kotlin.test.Test
import kotlin.test.assertEquals

/** attempt source 不能泄漏到下一轮长期回连。 */
class BleReconnectSourcePolicyTest {

    @Test
    fun `manual pending survives automatic lifecycle reactivation`() {
        assertEquals(
            BleConnectSource.MANUAL_RECONNECT,
            BleReconnectSourcePolicy.onArm(
                current = BleConnectSource.MANUAL_RECONNECT,
                incoming = BleConnectSource.AUTO_RECONNECT,
                businessConnected = false,
            ),
        )
    }

    @Test
    fun `manual business success makes next disconnect automatic`() {
        val afterBusinessConnected = BleReconnectSourcePolicy.onArm(
            current = BleConnectSource.MANUAL_RECONNECT,
            incoming = BleConnectSource.AUTO_RECONNECT,
            businessConnected = true,
        )

        assertEquals(BleConnectSource.AUTO_RECONNECT, afterBusinessConnected)
        assertEquals(
            BleConnectSource.AUTO_RECONNECT,
            BleReconnectSourcePolicy.afterTerminalAttempt(),
        )
    }

    @Test
    fun `bluetooth reset invalidates manual attempt source`() {
        assertEquals(
            BleConnectSource.AUTO_RECONNECT,
            BleReconnectSourcePolicy.afterTransportReset(),
        )
    }
}
