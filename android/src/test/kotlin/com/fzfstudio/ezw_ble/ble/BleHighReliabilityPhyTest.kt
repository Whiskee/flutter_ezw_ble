package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothProfile
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.mockito.Mockito

/** Exercise real readiness/OTA entry points; a pure RSSI-policy test misses out-of-band PHY writes. */
class BleHighReliabilityPhyTest {
    @Test
    fun `weak HR link stays 1M through readiness and OTA admission`() = withAndroidApi(26) {
        Fixture(highReliability = true).use { f ->
            f.connectAndFinishReadiness()
            f.enterOta()
            repeat(3) { f.callback.onReadRemoteRssi(f.gatt, -75, BluetoothGatt.GATT_SUCCESS) }
            assertEquals(listOf(1), f.phyRequests)
            assertEquals(BleConnectState.UPGRADE, f.device.connectState)
            Mockito.verify(f.gatt, Mockito.never()).readPhy()
        }
    }

    @Test
    fun `HR strong to weak fallback remains owned by adaptive callback across OTA entry`() = withAndroidApi(26) {
        Fixture(highReliability = true).use { f ->
            f.connectAndFinishReadiness()
            f.callback.onReadRemoteRssi(f.gatt, -60, BluetoothGatt.GATT_SUCCESS)
            f.enterOta()
            f.callback.onReadRemoteRssi(f.gatt, -65, BluetoothGatt.GATT_SUCCESS)
            f.callback.onReadRemoteRssi(f.gatt, -70, BluetoothGatt.GATT_SUCCESS)
            f.callback.onReadRemoteRssi(f.gatt, -75, BluetoothGatt.GATT_SUCCESS)
            assertEquals(listOf(1, 2, 1), f.phyRequests)
            assertEquals(listOf("phy_initial", "phy_promote", "phy_fallback"), f.policyEvents)
        }
    }

    @Test
    fun `ordinary mode retains both direct 2M requests without enabling RSSI adaptation`() = withAndroidApi(26) {
        Fixture(highReliability = false).use { f ->
            f.connectAndFinishReadiness()
            f.enterOta()
            f.callback.onReadRemoteRssi(f.gatt, -75, BluetoothGatt.GATT_SUCCESS)
            assertEquals(listOf(2, 2), f.phyRequests)
            Mockito.verify(f.gatt, Mockito.times(2)).readPhy()
            assertEquals(emptyList(), f.policyEvents)
        }
    }

    @Test
    fun `pre O readiness and OTA still complete without a PHY API call`() = withAndroidApi(25) {
        for (highReliability in listOf(true, false)) {
            Fixture(highReliability).use { f ->
                f.connectAndFinishReadiness()
                f.enterOta()
                f.callback.onReadRemoteRssi(f.gatt, -55, BluetoothGatt.GATT_SUCCESS)
                assertEquals(emptyList(), f.phyRequests)
                assertEquals(BleConnectState.UPGRADE, f.device.connectState)
            }
        }
    }

    @Test
    fun `stale GATT cannot finish readiness or change current HR preference`() = withAndroidApi(26) {
        Fixture(highReliability = true).use { f ->
            f.connectAndFinishReadiness()
            val stale = Mockito.mock(BluetoothGatt::class.java)
            val peripheral = f.gatt.device
            Mockito.`when`(stale.device).thenReturn(peripheral)
            f.callback.onServicesDiscovered(stale, BluetoothGatt.GATT_SUCCESS)
            f.callback.onReadRemoteRssi(stale, -55, BluetoothGatt.GATT_SUCCESS)
            assertEquals(listOf(1), f.phyRequests)
            assertEquals(listOf(BleConnectState.CONNECT_FINISH), f.states)
            Mockito.verify(stale, Mockito.never()).setPreferredPhy(Mockito.anyInt(), Mockito.anyInt(), Mockito.anyInt())
        }
    }

    /** Mockable android.jar reports API 0. Scope the API override to each serial JVM test and restore it. */
    private fun withAndroidApi(api: Int, block: () -> Unit) {
        // Android's compile bootclasspath excludes JDK internals; use reflection only in the JVM fixture.
        val unsafeType = Class.forName("sun.misc.Unsafe")
        val unsafe = unsafeType.getDeclaredField("theUnsafe").let {
            it.isAccessible = true
            it.get(null)
        }
        val field = Build.VERSION::class.java.getDeclaredField("SDK_INT")
        val base = unsafeType.getMethod("staticFieldBase", java.lang.reflect.Field::class.java).invoke(unsafe, field)
        val offset = unsafeType.getMethod("staticFieldOffset", java.lang.reflect.Field::class.java).invoke(unsafe, field)
        val write = unsafeType.getMethod("putIntVolatile", Any::class.java, Long::class.javaPrimitiveType, Int::class.javaPrimitiveType)
        // Reflective read initializes VERSION before overriding the non-constant framework field.
        val previous = field.getInt(null)
        write.invoke(unsafe, base, offset, api)
        try {
            Mockito.mockStatic(Log::class.java).use {
                Mockito.mockStatic(SystemClock::class.java).use { clock ->
                    clock.`when`<Long> { SystemClock.elapsedRealtime() }.thenReturn(1000L)
                    Mockito.mockConstruction(
                        JSONObject::class.java,
                        Mockito.withSettings().defaultAnswer(Mockito.RETURNS_SELF),
                    ) { json, _ -> Mockito.`when`(json.toString()).thenReturn("{}") }.use {
                        block()
                    }
                }
            }
        } finally {
            write.invoke(unsafe, base, offset, previous)
        }
    }

    /** One exact physical session shared by callback and Manager, with no real timers or Android context left behind. */
    private class Fixture(highReliability: Boolean) : AutoCloseable {
        private val endpoint = "AA:BB:CC:DD:EE:71"
        private val serviceId = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5450")
        private val writeId = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5401")
        private val readId = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5402")
        val gatt: BluetoothGatt = Mockito.mock(BluetoothGatt::class.java)
        val phyRequests = mutableListOf<Int>()
        val policyEvents = mutableListOf<String>()
        val states = mutableListOf<BleConnectState>()
        val device = BleDevice(
            BleConfig.empty().copy(
                name = "phy-test",
                privateServices = listOf(BlePrivateService(serviceId.toString(), writeChars = writeId.toString(), readChars = readId.toString())),
                androidHighReliabilityMode = highReliability,
            ),
            "PHY test", endpoint, "test", -75, BleConnectState.SEARCH_SERVICE,
        )
        private val manager = BleManager.instance
        private val scopeField = BleManager::class.java.getDeclaredField("mainScope").also { it.isAccessible = true }
        private val previousScope = scopeField.get(manager)
        private val descriptor = Mockito.mock(BluetoothGattDescriptor::class.java)
        val callback: BleGattSessionCallback

        init {
            // Only the EventChannel dispatcher is substituted; Manager admission/state/PHY logic stays real.
            scopeField.set(manager, CoroutineScope(Dispatchers.Unconfined))
            val peripheral = Mockito.mock(BluetoothDevice::class.java)
            Mockito.`when`(gatt.device).thenReturn(peripheral)
            Mockito.`when`(peripheral.address).thenReturn(endpoint)
            Mockito.doAnswer {
                val tx = it.getArgument<Int>(0)
                assertEquals(tx, it.getArgument<Int>(1))
                assertEquals(BluetoothDevice.PHY_OPTION_NO_PREFERRED, it.getArgument<Int>(2))
                phyRequests += tx
                null
            }.`when`(gatt).setPreferredPhy(Mockito.anyInt(), Mockito.anyInt(), Mockito.anyInt())
            val service = Mockito.mock(BluetoothGattService::class.java)
            val write = Mockito.mock(BluetoothGattCharacteristic::class.java)
            val read = Mockito.mock(BluetoothGattCharacteristic::class.java)
            Mockito.`when`(gatt.getService(serviceId)).thenReturn(service)
            Mockito.`when`(service.getCharacteristic(writeId)).thenReturn(write)
            Mockito.`when`(service.getCharacteristic(readId)).thenReturn(read)
            Mockito.`when`(gatt.setCharacteristicNotification(read, true)).thenReturn(true)
            Mockito.`when`(read.getDescriptor(BleManager.cccdDescriptor)).thenReturn(descriptor)
            Mockito.`when`(descriptor.uuid).thenReturn(BleManager.cccdDescriptor)
            Mockito.`when`(descriptor.characteristic).thenReturn(read)
            @Suppress("DEPRECATION")
            Mockito.`when`(gatt.writeDescriptor(descriptor)).thenReturn(true)
            Mockito.`when`(gatt.requestMtu(Mockito.anyInt())).thenReturn(true)
            callback = BleGattSessionCallback(
                expectedUuid = endpoint, sessionGeneration = 7L, attemptGeneration = 11L,
                currentDeviceForGatt = { source, _ -> if (source === gatt) device else null },
                handleConnectState = { _, _, state, _ -> states += state },
                recordTraceStep = { _, _, _, _, _, _ -> }, recordTraceMtu = { _, _, _, _ -> },
                updateTraceRssi = { _, _ -> }, markTraceRssiRequested = {}, markTraceRssiFailed = {},
                recordPhysicalTrace = { _, _ -> }, updateTracePhy = { _, _ -> },
                updateTraceRequestedPriority = { _, _, _ -> },
                recordTracePhyPolicy = { _, trigger, _, _ -> policyEvents += trigger },
                onPhysicalConnected = { _, _ -> }, onSessionTerminal = { _, _, _ -> },
                isBluetoothEnabled = { true }, recoverInsufficientAuthorization = { _, _ -> },
                recoverStaleAttributeCache = { _, _ -> },
                securityGateAttempts = BleAndroidSecurityGateAttemptRegistry(),
                securityGateOwner = { BleAndroidSecurityGateOwner(endpoint, 7L, 11L, 1L, gatt) },
                onSecurityGateFailure = { _, _, _, _ -> BleAndroidSecurityRecoveryAction.RETRY },
                onSecurityGatePassed = {}, onSecurityGateUnavailable = { _, _ -> false },
                consumeDisconnectingState = { null }, onCharacteristicWriteComplete = { _, _, _, _ -> },
                activeG2OtaContextForEndpoint = { null }, emitReceiveData = {}, sendLog = { _, _ -> },
            )
        }

        /** Physical callback -> actual service/CCCD readiness -> actual MTU callback. */
        fun connectAndFinishReadiness() {
            callback.onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
            // Sampling is driven explicitly below, not by a wall-clock wait in the unit test.
            BleGattSessionCallback::class.java.getDeclaredMethod("stopAdaptiveLinkMonitoring")
                .also { it.isAccessible = true }.invoke(callback)
            callback.onServicesDiscovered(gatt, BluetoothGatt.GATT_SUCCESS)
            callback.onDescriptorWrite(gatt, descriptor, BluetoothGatt.GATT_SUCCESS)
            callback.onMtuChanged(gatt, 247, BluetoothGatt.GATT_SUCCESS)
            assertEquals(listOf(BleConnectState.CONNECT_FINISH), states)
        }

        /** Install the already-authenticated session prerequisite, then call the real OTA entry. */
        fun enterOta() {
            device.connectState = BleConnectState.CONNECTED
            managerField<MutableList<BleDevice>>("connectedDevices").add(device)
            managerField<MutableMap<String, BleConnectionAdmission>>("currentAdmissions")[endpoint.lowercase()] =
                BleConnectionAdmission(endpoint, 11L, 1L, BleConnectSource.AUTO_RECONNECT, 7L)
            manager.enterUpgradeState(endpoint)
        }

        override fun close() {
            BleGattSessionCallback::class.java.getDeclaredMethod("stopAdaptiveLinkMonitoring")
                .also { it.isAccessible = true }.invoke(callback)
            managerField<MutableList<BleDevice>>("connectedDevices").removeAll { it === device }
            managerField<MutableMap<String, BleConnectionAdmission>>("currentAdmissions").remove(endpoint.lowercase())
            managerField<MutableList<String>>("upgradeDevices").remove(endpoint)
            scopeField.set(manager, previousScope)
        }

        @Suppress("UNCHECKED_CAST")
        private fun <T> managerField(name: String): T = BleManager::class.java.getDeclaredField(name)
            .also { it.isAccessible = true }.get(manager) as T
    }
}
