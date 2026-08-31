package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class AndroidBleAdaptiveLinkPolicyTest {
    @Test
    fun `high reliability connection starts on one megabit phy`() {
        assertEquals(
            BluetoothDevice.PHY_LE_1M_MASK,
            AndroidBleAdaptiveLinkPolicy.initialConnectPhyMask(highReliabilityMode = true),
        )
        assertEquals(
            BluetoothDevice.PHY_LE_2M_MASK,
            AndroidBleAdaptiveLinkPolicy.initialConnectPhyMask(highReliabilityMode = false),
        )
    }

    @Test
    fun `rssi thresholds use hysteresis between two megabit and one megabit phy`() {
        assertEquals(
            BluetoothDevice.PHY_LE_2M,
            AndroidBleAdaptiveLinkPolicy.preferredPhy(BluetoothDevice.PHY_LE_1M, -55),
        )
        assertEquals(
            BluetoothDevice.PHY_LE_1M,
            AndroidBleAdaptiveLinkPolicy.preferredPhy(BluetoothDevice.PHY_LE_2M, -75),
        )
        assertEquals(
            BluetoothDevice.PHY_LE_2M,
            AndroidBleAdaptiveLinkPolicy.preferredPhy(BluetoothDevice.PHY_LE_2M, -65),
        )
        assertEquals(
            BluetoothDevice.PHY_LE_1M,
            AndroidBleAdaptiveLinkPolicy.preferredPhy(BluetoothDevice.PHY_LE_1M, -65),
        )
    }

    @Test
    fun `connection priority stays high only inside recent traffic window`() {
        assertTrue(AndroidBleAdaptiveLinkPolicy.shouldUseHighPriority(nowMs = 9_999, lastActivityAtMs = 0))
        assertFalse(AndroidBleAdaptiveLinkPolicy.shouldUseHighPriority(nowMs = 10_000, lastActivityAtMs = 0))
    }
}
