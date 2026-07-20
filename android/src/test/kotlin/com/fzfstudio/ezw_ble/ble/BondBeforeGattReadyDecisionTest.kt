package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** R1 系统配对必须先于 GATT readiness，且所有分支都可脱离 Android callback 单测。 */
class BondBeforeGattReadyDecisionTest {

    @Test
    fun `binding disabled always discovers services without proactive bonding`() {
        SystemBondState.entries.forEach { state ->
            assertEquals(
                GateGrantedBondAction.DISCOVER_SERVICES,
                decideGateGrantedBondAction(initiateBinding = false, bondState = state),
            )
        }
    }

    @Test
    fun `binding enabled starts or waits for bond before service discovery`() {
        assertEquals(
            GateGrantedBondAction.START_BOND,
            decideGateGrantedBondAction(true, SystemBondState.NONE),
        )
        assertEquals(
            GateGrantedBondAction.WAIT_FOR_BOND,
            decideGateGrantedBondAction(true, SystemBondState.BONDING),
        )
        assertEquals(
            GateGrantedBondAction.DISCOVER_SERVICES,
            decideGateGrantedBondAction(true, SystemBondState.BONDED),
        )
        assertEquals(
            GateGrantedBondAction.WAIT_FOR_BOND,
            decideGateGrantedBondAction(true, SystemBondState.UNKNOWN),
        )
    }

    @Test
    fun `bond broadcast only advances the exact active binding stage`() {
        assertEquals(
            BondBroadcastAction.DISCOVER_SERVICES,
            decideBondBroadcastAction(
                initiateBinding = true,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.BONDED,
                previousBondState = SystemBondState.BONDING,
            ),
        )
        assertEquals(
            BondBroadcastAction.FAIL_BINDING,
            decideBondBroadcastAction(
                initiateBinding = true,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.NONE,
                previousBondState = SystemBondState.BONDING,
            ),
        )
        assertEquals(
            BondBroadcastAction.DISCOVER_SERVICES,
            decideBondBroadcastAction(
                initiateBinding = true,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.BONDED,
                previousBondState = SystemBondState.NONE,
            ),
            "Android may jump directly from NONE to BONDED",
        )
        assertEquals(
            BondBroadcastAction.IGNORE,
            decideBondBroadcastAction(
                initiateBinding = true,
                connectState = BleConnectState.CONNECTED,
                bondState = SystemBondState.NONE,
                previousBondState = SystemBondState.BONDING,
            ),
        )
        assertEquals(
            BondBroadcastAction.IGNORE,
            decideBondBroadcastAction(
                initiateBinding = false,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.BONDED,
                previousBondState = SystemBondState.NONE,
            ),
        )
        assertEquals(
            BondBroadcastAction.IGNORE,
            decideBondBroadcastAction(
                initiateBinding = true,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.NONE,
                previousBondState = SystemBondState.NONE,
            ),
        )
    }

    @Test
    fun `createBond false fails only while framework remains unbonded`() {
        assertTrue(
            shouldFailRejectedCreateBond(
                createBondStarted = false,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.NONE,
            ),
        )
        assertTrue(
            shouldFailRejectedCreateBond(
                createBondStarted = false,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.UNKNOWN,
            ),
        )
        assertFalse(
            shouldFailRejectedCreateBond(
                createBondStarted = false,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.BONDING,
            ),
        )
        assertFalse(
            shouldFailRejectedCreateBond(
                createBondStarted = false,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.BONDED,
            ),
        )
        assertFalse(
            shouldFailRejectedCreateBond(
                createBondStarted = true,
                connectState = BleConnectState.START_BINDING,
                bondState = SystemBondState.NONE,
            ),
        )
    }

    @Test
    fun `raw Android bond states map fail closed`() {
        assertEquals(SystemBondState.NONE, systemBondStateOf(10))
        assertEquals(SystemBondState.BONDING, systemBondStateOf(11))
        assertEquals(SystemBondState.BONDED, systemBondStateOf(12))
        assertEquals(SystemBondState.UNKNOWN, systemBondStateOf(-1))
    }

    @Test
    fun `waiting for bond retains the current gate owner`() {
        val gate = BleConnectionAdmissionGate()
        val ring = BleConnectionAdmission("ring", 1, 81, BleConnectSource.AUTO_RECONNECT)
        val glasses = BleConnectionAdmission("glasses", 1, 82, BleConnectSource.AUTO_RECONNECT)
        listOf(ring, glasses).forEach { gate.registerAttempt(it.endpointId, it.generation) }
        gate.onPhysicalConnected(ring)
        gate.onPhysicalConnected(glasses)

        assertEquals(
            GateGrantedBondAction.WAIT_FOR_BOND,
            decideGateGrantedBondAction(true, SystemBondState.BONDING),
        )
        assertTrue(gate.isActive(ring))
        assertFalse(gate.isActive(glasses))
    }
}
