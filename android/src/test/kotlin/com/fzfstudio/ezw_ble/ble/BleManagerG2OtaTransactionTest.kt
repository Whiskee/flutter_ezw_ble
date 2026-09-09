package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.util.Log
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.BleScan
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import java.lang.ref.WeakReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.mockito.Mockito

/** Manager-level regression coverage for Android OTA cleanup after GATT/cache loss. */
class BleManagerG2OtaTransactionTest {

    @Test
    fun `ota recovery retires the exact disconnected business gatt before session rebind`() {
        val manager = BleManager.instance
        resetManager(manager)
        val endpoint = "AA:BB:CC:DD:EE:60"
        val peerEndpoint = "AA:BB:CC:DD:EE:69"

        Mockito.mockStatic(Log::class.java).use {
            configureBle(manager, g2Config())
            setBleAvailable(manager)
            val device = installExactBusinessReadyEndpoint(
                manager = manager,
                endpoint = endpoint,
                name = "Even-R",
                sn = "SN-MANAGER",
                sessionGeneration = 1L,
                attemptGeneration = 1L,
            )
            val oldGatt = device.myGatt!!
            val peer = installExactBusinessReadyEndpoint(
                manager = manager,
                endpoint = peerEndpoint,
                name = "Even-Peer",
                sn = "SN-PEER",
                sessionGeneration = 9L,
                attemptGeneration = 9L,
            )
            val peerGatt = peer.myGatt!!

            // Business connected has already released the Gate admission; the exact
            // long-lived GATT metadata remains until OTA recovery replaces that owner.
            currentAdmissions(manager).remove(endpoint.lowercase())
            admittedGattSessions(manager).remove(1L)
            val endpoints = listOf(BleG2OtaEndpointIdentity(endpoint, "Even-R", 1L, 1L))
            val begin = manager.beginG2OtaTransaction(
                transactionId = "tx-session-rebind",
                generation = 16L,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )
            val instanceId = begin["instanceId"] as String
            val recover = manager.updateG2OtaEndpoint(
                transactionId = "tx-session-rebind",
                generation = 16L,
                instanceId = instanceId,
                uuid = endpoint,
                action = BleG2OtaEndpointAction.RECOVER,
                sessionGeneration = 1L,
                attemptGeneration = 1L,
            )
            device.connectState = BleConnectState.DISCONNECT_FROM_SYS

            val context = BleG2OtaNativeContext("tx-session-rebind", 16L, instanceId)
            val ordinaryRejected = invokeSessionRebindInvalidation(
                manager,
                endpoint,
                oldGatt,
                otaRecoveryContext = null,
            )
            assertFalse(ordinaryRejected)
            assertSame(oldGatt, device.myGatt)
            val staleRejected = invokeSessionRebindInvalidation(
                manager,
                endpoint,
                oldGatt,
                otaRecoveryContext = context.copy(transactionId = "tx-stale"),
            )
            assertFalse(staleRejected)
            assertSame(oldGatt, device.myGatt)

            // A concurrently registered attempt is stronger evidence than the stale
            // business cache, so recovery must not tear either owner down.
            currentAdmissions(manager)[endpoint.lowercase()] = BleConnectionAdmission(
                endpointId = endpoint,
                generation = 2L,
                sessionId = 200L,
                source = BleConnectSource.AUTO_RECONNECT,
                sessionGeneration = 2L,
            )
            val inFlightRejected = invokeSessionRebindInvalidation(
                manager,
                endpoint,
                oldGatt,
                otaRecoveryContext = context,
            )
            assertFalse(inFlightRejected)
            assertSame(oldGatt, device.myGatt)
            currentAdmissions(manager).remove(endpoint.lowercase())

            val retired = invokeSessionRebindInvalidation(manager, endpoint, oldGatt, context)
            val replayRejected = invokeSessionRebindInvalidation(manager, endpoint, oldGatt, context)

            assertEquals("accepted", begin["status"])
            assertEquals("accepted", recover["status"])
            assertTrue(retired)
            assertFalse(replayRejected)
            assertNull(device.myGatt)
            assertFalse(businessConnectedGattSessions(manager).containsKey(endpoint.lowercase()))
            assertSame(peerGatt, peer.myGatt)
            Mockito.verify(oldGatt, Mockito.times(1)).disconnect()
            Mockito.verify(oldGatt, Mockito.times(1)).close()
            Mockito.verify(peerGatt, Mockito.never()).disconnect()
            Mockito.verify(peerGatt, Mockito.never()).close()
        }
    }

    @Test
    fun `group finish rejects reentrant activation and writes before releasing either endpoint gate`() {
        val manager = BleManager.instance
        resetManager(manager)
        val left = "AA:BB:CC:DD:EE:61"
        val right = "AA:BB:CC:DD:EE:62"
        val peer = "AA:BB:CC:DD:EE:63"
        val endpoints = listOf(
            BleG2OtaEndpointIdentity(left, "Even-L", 61, 62),
            BleG2OtaEndpointIdentity(right, "Even-R", 63, 64),
        )
        val callbacks = mutableListOf<String>()

        // Android's JVM stub cannot serialize the real disconnect callback payload;
        // mock only that framework boundary, keeping Manager cleanup/reentry real.
        Mockito.mockConstruction(
            JSONObject::class.java,
            Mockito.withSettings().defaultAnswer(Mockito.RETURNS_SELF),
        ) { json, _ -> Mockito.`when`(json.toString()).thenReturn("{}") }.use {
            Mockito.mockStatic(Log::class.java).use {
                configureBle(manager, g2Config())
                setBleAvailable(manager)
                for (endpoint in endpoints) {
                    installExactBusinessReadyEndpoint(
                        manager, endpoint.uuid, endpoint.name, "SN-MANAGER",
                        endpoint.sessionGeneration, endpoint.attemptGeneration,
                    )
                }
                val untouchedPeer = installExactBusinessReadyEndpoint(
                    manager, peer, "Unrelated-Peer", "SN-PEER", 65, 66,
                )
                val peerGatt = untouchedPeer.myGatt!!
                val begin = manager.beginG2OtaTransaction(
                    "tx-manager-reentrant", 15, "g2_glasses", "SN-MANAGER", endpoints,
                )
                assertEquals("accepted", begin["status"])
                val instanceId = begin["instanceId"] as String

                for (endpoint in endpoints) {
                    val queue = BleAndroidOtaWriteQueue(
                        endpoint = endpoint.uuid,
                        submit = { _, _, _, _, _, _ -> BleOtaWriteSubmission.accepted() },
                        scheduler = BleOtaWriteScheduler { _, _ -> BleOtaWriteCancellable {} },
                        nowMillis = { 0L },
                    )
                    // A real queue cancellation completion re-enters the production Manager
                    // while finish is between endpoint teardowns, not a test-only state hook.
                    queue.enqueue(byteArrayOf(1)) { error ->
                        assertEquals("ota_write_cancelled", error?.code)
                        callbacks.add(endpoint.uuid)
                        if (endpoint.uuid == right) {
                            assertFalse(upgradeDevices(manager).any { it.equals(left, true) })
                        }
                        for (target in endpoints) {
                            val activation = manager.activateAutoReconnectTargets(
                                listOf(BleReconnectSeed("g2_glasses", target.uuid, target.name, "SN-MANAGER", 0)),
                                BleConnectSource.AUTO_RECONNECT,
                            ).single()
                            assertEquals("otaInProgress", activation.reason)
                            val writeResults = mutableListOf<BleOtaWriteError?>()
                            manager.sendCmdNoWait(
                                uuid = target.uuid,
                                data = byteArrayOf(2),
                                psType = 1,
                                expectedSessionGeneration = target.sessionGeneration,
                                expectedAttemptGeneration = target.attemptGeneration,
                                otaTransactionId = "tx-manager-reentrant",
                                otaGeneration = 15,
                                otaInstanceId = instanceId,
                            ) { writeResults.add(it) }
                            assertEquals("ota transaction mismatch", writeResults.single()?.reason)
                        }
                    }
                    otaWriteQueues(manager)[endpoint.uuid.lowercase()] = queue
                }

                fun finish() = manager.finishG2OtaTransaction(
                    "tx-manager-reentrant", 15, instanceId, "success",
                    "g2_glasses", "SN-MANAGER", endpoints,
                )
                assertEquals("committed", finish()["status"])
                assertEquals(listOf(left, right), callbacks)
                assertEquals("alreadyCommitted", finish()["status"])
                assertEquals(listOf(left, right), callbacks)
                assertTrue(otaWriteQueues(manager).isEmpty())
                assertTrue(upgradeDevices(manager).none { marker ->
                    endpoints.any { it.uuid.equals(marker, true) }
                })
                assertTrue(untouchedPeer.myGatt === peerGatt)
                Mockito.verify(peerGatt, Mockito.never()).disconnect()
                Mockito.verify(peerGatt, Mockito.never()).close()
            }
            }
    }

    @Test
    fun `finish retires marker and ota queue even when endpoint has no live gatt cache`() {
        val manager = BleManager.instance
        resetManager(manager)
        val endpoint = "AA:BB:CC:DD:EE:10"
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = BleAndroidOtaWriteQueue(
            endpoint = endpoint,
            submit = { _, _, _, _, _, _ -> BleOtaWriteSubmission.accepted() },
            scheduler = BleOtaWriteScheduler { _, _ -> BleOtaWriteCancellable {} },
            nowMillis = { 0L },
        )
        queue.enqueue(byteArrayOf(0x01)) { completions.add(it) }
        otaWriteQueues(manager)[endpoint.lowercase()] = queue

        Mockito.mockStatic(Log::class.java).use {
            configureBle(manager, g2Config())
            setBleAvailable(manager)
            val device = installExactBusinessReadyEndpoint(
                manager = manager,
                endpoint = endpoint,
                name = "Even-L",
                sn = "SN-MANAGER",
                sessionGeneration = 31L,
                attemptGeneration = 32L,
            )
            val endpoints = listOf(BleG2OtaEndpointIdentity(endpoint, "Even-L", 31, 32))
            val begin = manager.beginG2OtaTransaction(
                transactionId = "tx-manager-gatt-null",
                generation = 9,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )
            val instanceId = begin["instanceId"] as String
            device.releaseAndClear()

            val finish = manager.finishG2OtaTransaction(
                transactionId = "tx-manager-gatt-null",
                generation = 9,
                instanceId = instanceId,
                reason = "success",
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )
            val replay = manager.finishG2OtaTransaction(
                transactionId = "tx-manager-gatt-null",
                generation = 9,
                instanceId = instanceId,
                reason = "success",
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )

            assertEquals("accepted", begin["status"])
            assertEquals("committed", finish["status"])
            assertEquals("alreadyCommitted", replay["status"])
            assertEquals("ota_write_cancelled", completions.single()?.code)
            assertTrue(otaWriteQueues(manager).isEmpty())
            assertTrue(upgradeDevices(manager).none { it.equals(endpoint, ignoreCase = true) })
            assertTrue(!queue.hasOutstandingGattWrite)
        }
    }

    @Test
    fun `begin rejects dart fabricated scope and does not install upgrade marker`() {
        val manager = BleManager.instance
        resetManager(manager)
        val endpoint = "AA:BB:CC:DD:EE:20"

        Mockito.mockStatic(Log::class.java).use {
            configureBle(manager, g2Config())
            val begin = manager.beginG2OtaTransaction(
                transactionId = "tx-invalid-scope",
                generation = 10,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = listOf(BleG2OtaEndpointIdentity(endpoint, "Even-L", 1, 1)),
            )

            assertEquals("invalidRequest", begin["status"])
            assertEquals("unknownEndpoint", begin["reason"])
            assertFalse(upgradeDevices(manager).any { it.equals(endpoint, ignoreCase = true) })
        }
    }

    @Test
    fun `begin accepts waiting endpoint only when native already knows frozen G2 target`() {
        val manager = BleManager.instance
        resetManager(manager)
        val endpoint = "AA:BB:CC:DD:EE:30"

        Mockito.mockStatic(Log::class.java).use {
            configureBle(manager, g2Config())
            connectedDevices(manager).add(
                BleDevice(
                    belongConfig = g2Config(),
                    name = "Even-Waiting",
                    uuid = endpoint,
                    sn = "SN-MANAGER",
                    rssi = 0,
                    connectState = BleConnectState.NONE,
                ),
            )

            val begin = manager.beginG2OtaTransaction(
                transactionId = "tx-waiting-known-target",
                generation = 11,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = listOf(BleG2OtaEndpointIdentity(endpoint, "Even-Waiting", 0, 0)),
            )

            assertEquals("accepted", begin["status"])
            assertTrue(upgradeDevices(manager).any { it.equals(endpoint, ignoreCase = true) })
        }
    }

    @Test
    fun `stale ota transaction context cannot fall back to legacy write path`() {
        val manager = BleManager.instance
        resetManager(manager)
        val endpoint = "AA:BB:CC:DD:EE:40"
        val completions = mutableListOf<BleOtaWriteError?>()

        Mockito.mockStatic(Log::class.java).use {
            configureBle(manager, g2Config())
            setBleAvailable(manager)
            val device = installExactBusinessReadyEndpoint(
                manager = manager,
                endpoint = endpoint,
                name = "Even-L",
                sn = "SN-MANAGER",
                sessionGeneration = 41L,
                attemptGeneration = 42L,
            )
            val endpoints = listOf(BleG2OtaEndpointIdentity(endpoint, "Even-L", 41, 42))
            val begin = manager.beginG2OtaTransaction(
                transactionId = "tx-stale-write",
                generation = 12,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )
            val instanceId = begin["instanceId"] as String
            device.releaseAndClear()
            val finish = manager.finishG2OtaTransaction(
                transactionId = "tx-stale-write",
                generation = 12,
                instanceId = instanceId,
                reason = "success",
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )

            manager.sendCmdNoWait(
                uuid = endpoint,
                data = byteArrayOf(0x01),
                psType = 1,
                expectedSessionGeneration = 41L,
                expectedAttemptGeneration = 42L,
                otaTransactionId = "tx-stale-write",
                otaGeneration = 12L,
                otaInstanceId = instanceId,
            ) { completions.add(it) }

            assertEquals("committed", finish["status"])
            assertEquals("ota_write_unavailable", completions.single()?.code)
            assertEquals("ota transaction mismatch", completions.single()?.reason)
        }
    }

    @Test
    fun `begin replay keeps same transaction after acknowledged gatt disappears`() {
        val manager = BleManager.instance
        resetManager(manager)
        val endpoint = "AA:BB:CC:DD:EE:50"

        Mockito.mockStatic(Log::class.java).use {
            configureBle(manager, g2Config())
            val device = installExactBusinessReadyEndpoint(
                manager = manager,
                endpoint = endpoint,
                name = "Even-L",
                sn = "SN-MANAGER",
                sessionGeneration = 51L,
                attemptGeneration = 52L,
            )
            val endpoints = listOf(BleG2OtaEndpointIdentity(endpoint, "Even-L", 51, 52))
            val first = manager.beginG2OtaTransaction(
                transactionId = "tx-begin-replay",
                generation = 13,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )
            val instanceId = first["instanceId"] as String
            device.releaseAndClear()

            val replay = manager.beginG2OtaTransaction(
                transactionId = "tx-begin-replay",
                generation = 13,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )
            val conflict = manager.beginG2OtaTransaction(
                transactionId = "tx-begin-replay",
                generation = 14,
                config = "g2_glasses",
                sn = "SN-MANAGER",
                endpoints = endpoints,
            )

            assertEquals("accepted", first["status"])
            assertEquals("accepted", replay["status"])
            assertEquals(instanceId, replay["instanceId"])
            assertEquals("invalidRequest", conflict["status"])
            assertEquals("scopeConflict", conflict["reason"])
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun otaWriteQueues(manager: BleManager): MutableMap<String, BleAndroidOtaWriteQueue> {
        val field = BleManager::class.java.getDeclaredField("otaWriteQueues")
        field.isAccessible = true
        return field.get(manager) as MutableMap<String, BleAndroidOtaWriteQueue>
    }

    @Suppress("UNCHECKED_CAST")
    private fun upgradeDevices(manager: BleManager): MutableList<String> {
        val field = BleManager::class.java.getDeclaredField("upgradeDevices")
        field.isAccessible = true
        return field.get(manager) as MutableList<String>
    }

    @Suppress("UNCHECKED_CAST")
    private fun connectedDevices(manager: BleManager): MutableList<BleDevice> {
        val field = BleManager::class.java.getDeclaredField("connectedDevices")
        field.isAccessible = true
        return field.get(manager) as MutableList<BleDevice>
    }

    @Suppress("UNCHECKED_CAST")
    private fun currentAdmissions(manager: BleManager): MutableMap<String, BleConnectionAdmission> {
        val field = BleManager::class.java.getDeclaredField("currentAdmissions")
        field.isAccessible = true
        return field.get(manager) as MutableMap<String, BleConnectionAdmission>
    }

    @Suppress("UNCHECKED_CAST")
    private fun admittedGattSessions(manager: BleManager): MutableMap<Long, Any> {
        val field = BleManager::class.java.getDeclaredField("admittedGattSessions")
        field.isAccessible = true
        return field.get(manager) as MutableMap<Long, Any>
    }

    @Suppress("UNCHECKED_CAST")
    private fun businessConnectedGattSessions(manager: BleManager): MutableMap<String, Any> {
        val field = BleManager::class.java.getDeclaredField("businessConnectedGattSessions")
        field.isAccessible = true
        return field.get(manager) as MutableMap<String, Any>
    }

    private fun configureBle(manager: BleManager, config: BleConfig) {
        val field = BleManager::class.java.getDeclaredField("bleConfigs")
        field.isAccessible = true
        field.set(manager, listOf(config))
    }

    private fun invokeSessionRebindInvalidation(
        manager: BleManager,
        endpoint: String,
        gatt: BluetoothGatt,
        otaRecoveryContext: BleG2OtaNativeContext?,
    ): Boolean {
        val method = BleManager::class.java.getDeclaredMethod(
            "invalidatePassiveGattForSessionRebind",
            String::class.java,
            BluetoothGatt::class.java,
            BleG2OtaNativeContext::class.java,
        )
        method.isAccessible = true
        return method.invoke(manager, endpoint, gatt, otaRecoveryContext) as Boolean
    }

    private fun installExactBusinessReadyEndpoint(
        manager: BleManager,
        endpoint: String,
        name: String,
        sn: String,
        sessionGeneration: Long,
        attemptGeneration: Long,
    ): BleDevice {
        val config = g2Config()
        val gatt = Mockito.mock(BluetoothGatt::class.java)
        val commonWrite = readyCharacteristic()
        val commonRead = readyCharacteristic()
        val otaWrite = readyCharacteristic()
        val otaRead = readyCharacteristic()
        val device = BleDevice(
            belongConfig = config,
            name = name,
            uuid = endpoint,
            sn = sn,
            rssi = 0,
            connectState = BleConnectState.CONNECTED,
        )
        device.update(gatt, 0, commonWrite, commonRead)
        device.markNotifyReady(0)
        device.update(gatt, 1, otaWrite, otaRead)
        device.markNotifyReady(1)
        connectedDevices(manager).add(device)

        val admission = BleConnectionAdmission(
            endpointId = endpoint,
            generation = attemptGeneration,
            sessionId = attemptGeneration,
            source = BleConnectSource.AUTO_RECONNECT,
            sessionGeneration = sessionGeneration,
        )
        val granted = constructPrivateManagerValue(
            "com.fzfstudio.ezw_ble.ble.BleManager\$GrantedGattSession",
            admission,
            gatt,
            device,
            false,
            false,
            false,
        )
        val business = constructPrivateManagerValue(
            "com.fzfstudio.ezw_ble.ble.BleManager\$BusinessConnectedGattSession",
            admission,
            gatt,
        )
        currentAdmissions(manager)[endpoint.lowercase()] = admission
        admittedGattSessions(manager)[admission.sessionId] = granted
        businessConnectedGattSessions(manager)[endpoint.lowercase()] = business
        return device
    }

    private fun constructPrivateManagerValue(className: String, vararg args: Any): Any {
        val constructor = Class.forName(className).declaredConstructors.single {
            it.parameterCount == args.size
        }
        constructor.isAccessible = true
        return constructor.newInstance(*args)
    }

    private fun readyCharacteristic(): BluetoothGattCharacteristic {
        val characteristic = Mockito.mock(BluetoothGattCharacteristic::class.java)
        Mockito.`when`(characteristic.properties).thenReturn(
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_WRITE,
        )
        return characteristic
    }

    private fun g2Config(): BleConfig = BleConfig(
        name = "g2_glasses",
        scan = BleScan.empty(),
        privateServices = listOf(
            BlePrivateService(
                service = "00000000-0000-1000-8000-00805f9b34fb",
                writeChars = "00000001-0000-1000-8000-00805f9b34fb",
                readChars = "00000002-0000-1000-8000-00805f9b34fb",
                type = 0,
            ),
            BlePrivateService(
                service = "00002760-08C2-11E1-9073-0E8AC72E1001",
                writeChars = "00002760-08C2-11E1-9073-0E8AC72E0001",
                readChars = "00002760-08C2-11E1-9073-0E8AC72E0002",
                type = 1,
            ),
        ),
        initiateBinding = true,
        connectTimeout = 15000.0,
        upgradeSwapTime = 60000.0,
        mtu = 247,
        autoReconnect = true,
    )

    private fun resetManager(manager: BleManager) {
        setWeakContext(manager, null)
        setMainScope(manager)
        manager.cleanConnectCache()
    }

    private fun setMainScope(manager: BleManager) {
        val field = BleManager::class.java.getDeclaredField("mainScope")
        field.isAccessible = true
        field.set(manager, CoroutineScope(Dispatchers.Unconfined))
    }

    private fun setWeakContext(manager: BleManager, context: WeakReference<android.content.Context>?) {
        val field = BleManager::class.java.getDeclaredField("weakContext")
        field.isAccessible = true
        field.set(manager, context)
    }

    private fun setBleAvailable(manager: BleManager) {
        setPrivateField(manager, "bleState", 5)
        setPrivateField(manager, "blePermission", true)
        setPrivateField(manager, "bleLocation", true)
    }

    private fun setPrivateField(manager: BleManager, name: String, value: Any) {
        val field = BleManager::class.java.getDeclaredField(name)
        field.isAccessible = true
        field.set(manager, value)
    }
}
