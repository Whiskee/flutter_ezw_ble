package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.mockito.Mockito
import java.util.UUID

/** Exercise the real GATT callback so suppressing logs cannot swallow write completions. */
class BleOtaWriteCallbackLoggingTest {
    @BeforeTest
    fun ordinaryMode() = BleOtaDebugLogPolicy.setEnabled(false)

    @AfterTest
    fun resetPolicy() = BleOtaDebugLogPolicy.setEnabled(false)

    @Test
    fun `ordinary ota success callbacks remain delivered without detail logs`() {
        val fixture = CallbackFixture(psType = 1)

        repeat(1_000) { fixture.callback.onCharacteristicWrite(fixture.gatt, fixture.characteristic, 0) }

        assertEquals(1_000, fixture.completions.size)
        assertTrue(fixture.completions.all { it == (1 to 0) })
        assertEquals(emptyList(), fixture.logs)
    }

    @Test
    fun `normal and unknown channel successes and ota failures retain diagnostics`() {
        listOf(0, null).forEach { psType ->
            val fixture = CallbackFixture(psType)
            fixture.callback.onCharacteristicWrite(fixture.gatt, fixture.characteristic, 0)
            assertEquals(listOf(psType to 0), fixture.completions)
            assertTrue(fixture.logs.single().contains("write call back is success = true"))
        }
        val failedOta = CallbackFixture(psType = 1)
        failedOta.callback.onCharacteristicWrite(failedOta.gatt, failedOta.characteristic, 133)
        assertEquals(listOf<Pair<Int?, Int>>(1 to 133), failedOta.completions)
        assertTrue(failedOta.logs.single().contains("GATT_ERROR"))
    }

    @Test
    fun `debug toggle changes only the real ota callback log`() {
        val fixture = CallbackFixture(psType = 1)
        BleOtaDebugLogPolicy.setEnabled(true)
        fixture.callback.onCharacteristicWrite(fixture.gatt, fixture.characteristic, 0)
        assertTrue(fixture.logs.single().contains("write call back is success = true"))
        BleOtaDebugLogPolicy.setEnabled(false)
        fixture.callback.onCharacteristicWrite(fixture.gatt, fixture.characteristic, 0)
        assertEquals(1, fixture.logs.size)
        assertEquals(2, fixture.completions.size)
    }

    private class CallbackFixture(psType: Int?) {
        private val address = "AA:BB:CC:DD:EE:FF"
        val gatt: BluetoothGatt = Mockito.mock(BluetoothGatt::class.java)
        val characteristic: BluetoothGattCharacteristic = Mockito.mock(BluetoothGattCharacteristic::class.java)
        val completions = mutableListOf<Pair<Int?, Int>>()
        val logs = mutableListOf<String>()
        private val device = BleDevice(BleConfig.empty(), "G2", address, "sn", 0, BleConnectState.CONNECTED)
        val callback: BleGattSessionCallback

        init {
            val peripheral = Mockito.mock(BluetoothDevice::class.java)
            Mockito.`when`(gatt.device).thenReturn(peripheral)
            Mockito.`when`(peripheral.address).thenReturn(address)
            Mockito.`when`(characteristic.uuid).thenReturn(UUID.randomUUID())
            // Install actual characteristic mappings rather than overriding callback classification.
            if (psType != null) device.update(gatt, psType, characteristic, characteristic)
            callback = BleGattSessionCallback(
                expectedUuid = address, sessionGeneration = 7L, attemptGeneration = 11L,
                currentDeviceForGatt = { source, _ -> if (source === gatt) device else null },
                handleConnectState = { _, _, _, _ -> }, recordTraceStep = { _, _, _, _, _, _ -> },
                recordTraceMtu = { _, _, _, _ -> }, updateTraceRssi = { _, _ -> },
                markTraceRssiRequested = {}, markTraceRssiFailed = {}, recordPhysicalTrace = { _, _ -> },
                updateTracePhy = { _, _ -> }, updateTraceRequestedPriority = { _, _, _ -> },
                recordTracePhyPolicy = { _, _, _, _ -> }, onPhysicalConnected = { _, _ -> },
                onSessionTerminal = { _, _, _ -> }, isBluetoothEnabled = { true },
                recoverInsufficientAuthorization = { _, _ -> },
                recoverStaleAttributeCache = { _, _ -> }, consumeDisconnectingState = { null },
                securityGateAttempts = BleAndroidSecurityGateAttemptRegistry(),
                securityGateOwner = { source -> BleAndroidSecurityGateOwner(address, 7L, 11L, 1L, source) },
                onSecurityGateFailure = { _, _, _, _ -> error("ordinary write must not fail security gate") },
                onSecurityGatePassed = { error("ordinary write must not pass security gate") },
                onSecurityGateUnavailable = { _, _ -> error("ordinary write must not start bonding") },
                activeG2OtaContextForEndpoint = { null },
                onCharacteristicWriteComplete = { _, type, status, _ -> completions.add(type to status) },
                emitReceiveData = {}, sendLog = { _, message -> logs.add(message) },
            )
        }
    }
}
