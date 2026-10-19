package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.util.Base64
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.mockito.Mockito

/** Exercise the real notify callback: logging must never gate the ACK data or its exact owner. */
class BleOtaReceiveCallbackLoggingTest {
    @BeforeTest
    fun ordinaryMode() = BleOtaDebugLogPolicy.setEnabled(false)

    @AfterTest
    fun resetPolicy() = BleOtaDebugLogPolicy.setEnabled(false)

    @Test
    fun `ordinary ota notifications deliver a thousand intact receipts without formatting metadata`() {
        val fixture = CallbackFixture(psType = 1)
        withBase64 {
            repeat(1_000) { fixture.callback.onCharacteristicChanged(fixture.gatt, fixture.characteristic) }
        }

        assertEquals(1_000, fixture.events.size)
        fixture.events.forEach { fixture.assertReceipt(it, psType = 1) }
        assertEquals(emptyList(), fixture.logs)
        // One payload read is required to copy the business bytes. The metadata-only second
        // value access and writeType access must both disappear before interpolation.
        Mockito.verify(fixture.characteristic, Mockito.times(1_000)).value
        Mockito.verify(fixture.characteristic, Mockito.never()).writeType
    }

    @Test
    fun `debug toggle restores only metadata while exact ota receipts stay equal`() {
        val fixture = CallbackFixture(psType = 1)
        withBase64 {
            fixture.callback.onCharacteristicChanged(fixture.gatt, fixture.characteristic)
            BleOtaDebugLogPolicy.setEnabled(true)
            fixture.callback.onCharacteristicChanged(fixture.gatt, fixture.characteristic)
            BleOtaDebugLogPolicy.setEnabled(false)
            fixture.callback.onCharacteristicChanged(fixture.gatt, fixture.characteristic)
        }

        assertEquals(3, fixture.events.size)
        assertEquals(fixture.events[0], fixture.events[1])
        assertEquals(fixture.events[0], fixture.events[2])
        fixture.assertReceipt(fixture.events[0], psType = 1)
        assertEquals(listOf(BleLoggerTag.d to
            "Receive cmd(old): ${fixture.address}, type=1, length=3, chartsType=2"), fixture.logs)
        Mockito.verify(fixture.characteristic, Mockito.times(4)).value
        Mockito.verify(fixture.characteristic, Mockito.times(1)).writeType
    }

    @Test
    fun `ordinary non ota channels keep receive metadata and full bytes`() {
        listOf(0, 2).forEach { psType ->
            val fixture = CallbackFixture(psType)
            withBase64 { fixture.callback.onCharacteristicChanged(fixture.gatt, fixture.characteristic) }

            fixture.assertReceipt(fixture.events.single(), psType)
            assertEquals(BleLoggerTag.d, fixture.logs.single().first)
            assertTrue(fixture.logs.single().second.contains("type=$psType, length=3, chartsType=2"))
        }
    }

    @Test
    fun `missing gatt characteristic and unknown read uuid retain errors without publishing bytes`() {
        val fixture = CallbackFixture(psType = null)
        fixture.callback.onCharacteristicChanged(null, fixture.characteristic)
        fixture.callback.onCharacteristicChanged(fixture.gatt, null)
        fixture.callback.onCharacteristicChanged(fixture.gatt, fixture.characteristic)

        assertEquals(emptyList(), fixture.events)
        assertEquals(3, fixture.logs.size)
        assertTrue(fixture.logs.all { it.first == BleLoggerTag.e })
        assertTrue(fixture.logs[0].second.contains("gatt or characteristic is null"))
        assertTrue(fixture.logs[1].second.contains("gatt or characteristic is null"))
        assertTrue(fixture.logs[2].second.contains("not found current uuid"))
        Mockito.verify(fixture.characteristic, Mockito.never()).value
        Mockito.verify(fixture.characteristic, Mockito.never()).writeType
    }

    private fun withBase64(block: () -> Unit) {
        Mockito.mockStatic(Base64::class.java).use { base64 ->
            base64.`when`<String> {
                Base64.encodeToString(Mockito.any(ByteArray::class.java), Mockito.eq(Base64.NO_WRAP))
            }.thenAnswer { java.util.Base64.getEncoder().encodeToString(it.getArgument(0)) }
            block()
        }
    }

    private class CallbackFixture(psType: Int?) {
        val address = "AA:BB:CC:DD:EE:FF"
        val gatt: BluetoothGatt = Mockito.mock(BluetoothGatt::class.java)
        val characteristic: BluetoothGattCharacteristic = Mockito.mock(BluetoothGattCharacteristic::class.java)
        val events = mutableListOf<Map<String, Any?>>()
        val logs = mutableListOf<Pair<BleLoggerTag, String>>()
        val callback: BleGattSessionCallback

        init {
            val peripheral = Mockito.mock(BluetoothDevice::class.java)
            val characteristicId = UUID.randomUUID()
            Mockito.`when`(gatt.device).thenReturn(peripheral)
            Mockito.`when`(peripheral.address).thenReturn(address)
            Mockito.`when`(characteristic.uuid).thenReturn(characteristicId)
            Mockito.`when`(characteristic.value).thenReturn(byteArrayOf(1, 2, 3))
            Mockito.`when`(characteristic.writeType).thenReturn(2)
            val services = if (psType == null) emptyList() else listOf(
                BlePrivateService(UUID.randomUUID().toString(), readChars = characteristicId.toString(), type = psType),
            )
            val device = BleDevice(BleConfig.empty().copy(privateServices = services),
                "G2", address, "sn", 0, BleConnectState.CONNECTED)
            callback = BleGattSessionCallback(
                expectedUuid = address, sessionGeneration = 7L, attemptGeneration = 11L,
                currentDeviceForGatt = { source, _ -> if (source === gatt) device else null },
                handleConnectState = { _, _, _, _ -> }, recordTraceStep = { _, _, _, _, _, _ -> },
                recordTraceMtu = { _, _, _, _ -> }, updateTraceRssi = { _, _ -> },
                markTraceRssiRequested = {}, markTraceRssiFailed = {}, recordPhysicalTrace = { _, _ -> },
                updateTracePhy = { _, _ -> }, updateTraceRequestedPriority = { _, _, _ -> },
                recordTracePhyPolicy = { _, _, _, _ -> }, onPhysicalConnected = { _, _ -> },
                onSessionTerminal = { _, _, _ -> }, isBluetoothEnabled = { true },
                recoverInsufficientAuthorization = { _, _ -> }, consumeDisconnectingState = { null },
                securityGateAttempts = BleAndroidSecurityGateAttemptRegistry(),
                securityGateOwner = { source -> BleAndroidSecurityGateOwner(address, 7L, 11L, 1L, source) },
                onSecurityGateFailure = { _, _, _, _ -> error("Notify must not fail security gate") },
                onSecurityGatePassed = { error("Notify must not pass security gate") },
                onSecurityGateUnavailable = { _, _ -> error("Notify must not start bonding") },
                activeG2OtaContextForEndpoint = {
                    check(psType == 1) { "Non-OTA notify must not query transaction" }
                    BleG2OtaNativeContext("transaction", 13L, "instance")
                },
                onCharacteristicWriteComplete = { _, _, _, _ -> },
                emitReceiveData = { events.add(it) }, sendLog = { tag, message -> logs.add(tag to message) },
                captureReceiveIdentity = { BleBusinessConnectionAttempt(address, 7L, 11L) },
            )
        }

        fun assertReceipt(event: Map<String, Any?>, psType: Int) {
            assertEquals(address, event["uuid"])
            assertEquals(psType, event["psType"])
            assertEquals("AQID", event["data"])
            assertEquals(true, event["isSuccess"])
            assertEquals(7L, event["sessionGeneration"])
            assertEquals(11L, event["attemptGeneration"])
            assertEquals(mapOf("uuid" to address, "sessionGeneration" to 7L,
                "attemptGeneration" to 11L), event["receiveIdentity"])
            assertEquals(if (psType == 1) "transaction" else "", event["otaTransactionId"])
            assertEquals(if (psType == 1) 13L else 0L, event["otaGeneration"])
            assertEquals(if (psType == 1) "instance" else "", event["otaInstanceId"])
        }
    }
}
