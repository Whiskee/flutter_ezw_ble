package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 蓝牙关闭终态必须复用已建立会话的 source/generation，不能回退 unknown/0。 */
class BleBluetoothOffTerminalMetadataPolicyTest {

    @Test
    fun `current admission takes precedence over business-connected session`() {
        val current = admission(7, BleConnectSource.MANUAL_RECONNECT)
        val businessConnected = admission(6, BleConnectSource.AUTO_RECONNECT)

        assertEquals(
            current,
            BleBluetoothOffTerminalMetadataPolicy.resolve(current, businessConnected),
        )
    }

    @Test
    fun `business-connected session supplies metadata after gate release`() {
        val businessConnected = admission(8, BleConnectSource.AUTO_RECONNECT)

        assertEquals(
            businessConnected,
            BleBluetoothOffTerminalMetadataPolicy.resolve(null, businessConnected),
        )
    }

    @Test
    fun `unknown source or zero generation never becomes a bluetooth-off terminal`() {
        assertNull(
            BleBluetoothOffTerminalMetadataPolicy.resolve(
                admission(0, BleConnectSource.AUTO_RECONNECT),
                admission(4, BleConnectSource.UNKNOWN),
            ),
        )
    }

    @Test
    fun `last business-connected epoch survives OTA replacement of the exact session`() {
        val lastConnected = admission(7, BleConnectSource.AUTO_RECONNECT)

        assertEquals(
            lastConnected,
            BleBluetoothOffTerminalMetadataPolicy.resolve(
                currentAdmission = null,
                businessConnectedAdmission = null,
                lastBusinessConnectedAdmission = lastConnected,
            ),
        )
    }

    @Test
    fun `live current admission wins over the historical OTA fallback`() {
        val current = admission(9, BleConnectSource.MANUAL_RECONNECT)
        val lastConnected = admission(7, BleConnectSource.AUTO_RECONNECT)

        assertEquals(
            current,
            BleBluetoothOffTerminalMetadataPolicy.resolve(
                currentAdmission = current,
                businessConnectedAdmission = null,
                lastBusinessConnectedAdmission = lastConnected,
            ),
        )
    }

    @Test
    fun `system disconnect restores the exact manual business session metadata`() {
        val manualSession = admission(19, BleConnectSource.MANUAL_RECONNECT)

        assertEquals(
            BleTerminalMetadata(
                source = BleConnectSource.MANUAL_RECONNECT,
                sessionGeneration = manualSession.sessionGeneration,
                attemptGeneration = manualSession.generation,
            ),
            BleBluetoothOffTerminalMetadataPolicy.resolveTerminalMetadata(
                explicitSource = BleConnectSource.UNKNOWN,
                explicitSessionGeneration = 0L,
                explicitAttemptGeneration = 0L,
                fallbackAdmission = manualSession,
            ),
        )
    }

    @Test
    fun `explicit callback metadata wins over historical connected admission`() {
        val historical = admission(19, BleConnectSource.MANUAL_RECONNECT)

        assertEquals(
            BleTerminalMetadata(
                source = BleConnectSource.AUTO_RECONNECT,
                sessionGeneration = 21L,
                attemptGeneration = 24L,
            ),
            BleBluetoothOffTerminalMetadataPolicy.resolveTerminalMetadata(
                explicitSource = BleConnectSource.AUTO_RECONNECT,
                explicitSessionGeneration = 21L,
                explicitAttemptGeneration = 24L,
                fallbackAdmission = historical,
            ),
        )
    }

    @Test
    fun `missing business session never synthesizes an old terminal identity`() {
        assertEquals(
            BleTerminalMetadata(
                source = BleConnectSource.UNKNOWN,
                sessionGeneration = 0L,
                attemptGeneration = 7L,
            ),
            BleBluetoothOffTerminalMetadataPolicy.resolveTerminalMetadata(
                explicitSource = BleConnectSource.UNKNOWN,
                explicitSessionGeneration = 0L,
                explicitAttemptGeneration = 7L,
                fallbackAdmission = null,
            ),
        )
    }

    @Test
    fun `reconnect owner supplies bluetooth-off terminal only with an accepted epoch`() {
        assertEquals(
            BleTerminalMetadata(
                source = BleConnectSource.AUTO_RECONNECT,
                sessionGeneration = 17L,
                attemptGeneration = 19L,
            ),
            BleBluetoothOffTerminalMetadataPolicy.resolveReconnectOwnerTerminalMetadata(
                source = BleConnectSource.AUTO_RECONNECT,
                sessionGeneration = 17L,
                attemptGeneration = 19L,
            ),
        )
        assertNull(
            BleBluetoothOffTerminalMetadataPolicy.resolveReconnectOwnerTerminalMetadata(
                source = BleConnectSource.UNKNOWN,
                sessionGeneration = 17L,
                attemptGeneration = 19L,
            ),
        )
        assertNull(
            BleBluetoothOffTerminalMetadataPolicy.resolveReconnectOwnerTerminalMetadata(
                source = BleConnectSource.AUTO_RECONNECT,
                sessionGeneration = 0L,
                attemptGeneration = 19L,
            ),
        )
    }

    @Test
    fun `upgrade state cannot manufacture or resurrect a connected device`() {
        val accepted = admission(21, BleConnectSource.AUTO_RECONNECT)

        assertTrue(BleUpgradeStatePolicy.canEnter(BleConnectState.CONNECTED, accepted))
        assertFalse(BleUpgradeStatePolicy.canEnter(BleConnectState.CONNECT_FINISH, accepted))
        assertFalse(BleUpgradeStatePolicy.canEnter(BleConnectState.CONNECTED, null))
        assertTrue(BleUpgradeStatePolicy.canExitToConnected(BleConnectState.UPGRADE, accepted))
        assertFalse(
            BleUpgradeStatePolicy.canExitToConnected(
                BleConnectState.DISCONNECT_FROM_SYS,
                accepted,
            ),
        )
        assertFalse(BleUpgradeStatePolicy.canExitToConnected(BleConnectState.UPGRADE, null))
    }

    private fun admission(
        generation: Long,
        source: BleConnectSource,
    ) = BleConnectionAdmission(
        endpointId = "endpoint-$generation-${source.name}",
        generation = generation,
        sessionId = generation + 100L,
        source = source,
    )
}
