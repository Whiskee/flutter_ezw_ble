package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.util.Base64
import com.fzfstudio.ezw_ble.ble.models.*
import kotlin.test.Test
import org.mockito.Mockito
import kotlin.test.assertEquals
import java.util.UUID

/** Real callback freezes the accepted source before an external event queue is released. */
class BleReceiptCallbackTest {
    @Test
    fun `accepted notification keeps original pair and bytes across replacement`() {
        val uuid = "AA:BB:CC:DD:EE:FF"
        val gatt = Mockito.mock(BluetoothGatt::class.java)
        val peripheral = Mockito.mock(BluetoothDevice::class.java)
        val characteristic = Mockito.mock(BluetoothGattCharacteristic::class.java)
        val characteristicId = UUID.randomUUID()
        Mockito.`when`(gatt.device).thenReturn(peripheral)
        Mockito.`when`(peripheral.address).thenReturn(uuid)
        Mockito.`when`(characteristic.uuid).thenReturn(characteristicId)
        val bytes = byteArrayOf(1, 2, 3)
        Mockito.`when`(characteristic.value).thenReturn(bytes)
        val device = BleDevice(BleConfig.empty().copy(privateServices = listOf(
            BlePrivateService(UUID.randomUUID().toString(), readChars = characteristicId.toString()),
        )), "R1", uuid, "sn", 0, com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState.CONNECTED)
        var current = true
        val events = mutableListOf<Map<String, Any?>>()
        val callback = BleGattSessionCallback(
            // Match the retained GATT admission. These are physical owner values,
            // not diagnostic trace IDs; replacement must not restamp a receipt.
            expectedUuid = uuid, sessionGeneration = 7L, attemptGeneration = 11L,
            currentDeviceForGatt = { source, _ ->
                if (current && source === gatt) device else null
            },
            handleConnectState = { _, _, _, _ -> }, recordTraceStep = { _, _, _, _, _, _ -> },
            recordTraceMtu = { _, _, _, _ -> }, updateTraceRssi = { _, _ -> },
            markTraceRssiRequested = { }, markTraceRssiFailed = { },
            recordPhysicalTrace = { _, _ -> error("Notify must not create a physical connection event") },
            updateTracePhy = { _, _ -> }, updateTraceRequestedPriority = { _, _, _ -> },
            recordTracePhyPolicy = { _, _, _, _ -> }, onPhysicalConnected = { _, _ -> },
            onSessionTerminal = { _, _, _ -> }, isBluetoothEnabled = { true },
            recoverInsufficientAuthorization = { _, _ -> }, consumeDisconnectingState = { null },
            // This fixture receives ordinary R1 data on an already-ready GATT;
            // security admission must never be advanced by a notification.
            securityGateAttempts = BleAndroidSecurityGateAttemptRegistry(),
            securityGateOwner = { source -> BleAndroidSecurityGateOwner(uuid, 7L, 11L, 1L, source) },
            onSecurityGateFailure = { _, _, _, _ -> error("Notify must not fail security admission") },
            onSecurityGatePassed = { error("Notify must not pass security admission") },
            onSecurityGateUnavailable = { _, _ -> error("Notify must not start fallback bonding") },
            activeG2OtaContextForEndpoint = { error("Ordinary R1 data must not claim an OTA transaction") },
            onCharacteristicWriteComplete = { _, _, _, _ -> }, emitReceiveData = { events.add(it) },
            sendLog = { _, _ -> },
            captureReceiveIdentity = { source ->
                if (current && source === gatt) BleBusinessConnectionAttempt(uuid, 7, 11) else null
            },
        )
        Mockito.mockStatic(Base64::class.java).use { base64 ->
            base64.`when`<String> { Base64.encodeToString(bytes, Base64.NO_WRAP) }.thenAnswer {
                java.util.Base64.getEncoder().encodeToString(it.getArgument(0))
            }
            callback.onCharacteristicChanged(gatt, characteristic)
            current = false
            bytes[0] = 9
            callback.onCharacteristicChanged(gatt, characteristic)
            assertEquals(1, events.size)
            assertEquals("AQID", events.single()["data"])
            assertEquals(7L, events.single()["sessionGeneration"])
            assertEquals(11L, events.single()["attemptGeneration"])
            assertEquals(
                mapOf(
                    "uuid" to uuid,
                    "sessionGeneration" to 7L,
                    "attemptGeneration" to 11L,
                ),
                events.single()["receiveIdentity"],
            )
        }
    }

    @Test
    fun `legacy positive pair cannot replace rejected receive identity`() {
        val event = BleCmd(
            uuid = "AA:BB:CC:DD:EE:FF",
            psType = 0,
            data = byteArrayOf(1),
            isSuccess = true,
            sessionGeneration = 7L,
            attemptGeneration = 11L,
            receiveIdentity = null,
        )

        assertEquals(null, event.toFlutterMap()["receiveIdentity"])
        assertEquals(7L, event.toFlutterMap()["sessionGeneration"])
        assertEquals(11L, event.toFlutterMap()["attemptGeneration"])
    }
}
