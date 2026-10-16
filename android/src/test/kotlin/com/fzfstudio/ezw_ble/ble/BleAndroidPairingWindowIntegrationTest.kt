package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.services.BleStateListener.BluetoothStateCallback
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.mockito.Mockito
import java.util.IdentityHashMap
import java.util.Timer
import java.util.TimerTask
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Exercises real Manager + Supervisor entry points; only Android GATT and clock boundaries are fake. */
class BleAndroidPairingWindowIntegrationTest {
    @Test
    fun `foreground queues second unbonded leg before GATT and preserves request session`() = fixture { f ->
        f.foreground(f.left, 101L)
        f.foreground(f.right, 101L)
        assertEquals(listOf(f.left.uuid), f.opened)
        assertNull(f.right.device.myGatt)
        val queued = f.admission(f.right)
        f.foreground(f.right, 101L)
        assertEquals(queued, f.admission(f.right))
        assertEquals(101L, f.admission(f.right).sessionGeneration)
        val progress = f.payloads().filter { it["pairingPhase"] == "queuedBeforePhysical" }
        assertTrue(progress.isNotEmpty())
        progress.forEach { payload ->
            assertEquals("connecting", payload["connectState"])
            assertEquals(101L, payload["sessionGeneration"])
            assertEquals(queued.generation, payload["attemptGeneration"])
            assertEquals(f.right.uuid, payload["uuid"])
            assertEquals(f.right.name, payload["name"])
            assertEquals("foreground", payload["source"])
            assertFalse(payload.containsKey("nativeTrace"))
        }
        assertEquals(BleConnectState.NONE, f.right.device.connectState)
        // Physical contact does not release the serial owner; business commit or terminal does.
        f.contact(f.left)
        assertEquals(listOf(f.left.uuid), f.opened)
        f.manager.disconnect(f.left.uuid)
        assertEquals(listOf(f.left.uuid, f.right.uuid), f.opened)
        assertEquals(101L, f.admission(f.right).sessionGeneration)
    }

    @Test
    fun `higher foreground request replaces queued intent and stale request cannot revive it`() = fixture { f ->
        f.foreground(f.left, 301L)
        f.foreground(f.right, 301L)
        val old = f.admission(f.right)
        f.foreground(f.right, 302L)
        val current = f.admission(f.right)
        assertEquals(302L, current.sessionGeneration)
        assertTrue(current.generation > old.generation)
        assertFalse(f.pendingStarts().containsKey(old.sessionId))
        f.foreground(f.right, 301L)
        assertEquals(current, f.admission(f.right))
        assertEquals(listOf(f.left.uuid), f.opened)
        f.manager.disconnect(f.left.uuid)
        assertEquals(listOf(f.left.uuid, f.right.uuid), f.opened)
        assertEquals(current, f.admission(f.right))
    }

    @Test
    fun `twenty second confirmation and twenty one second bonded resume without failure`() = fixture { f ->
        f.foreground(f.left)
        f.contact(f.left)
        assertEquals(BleConnectState.START_BINDING, f.left.device.connectState)
        assertNull(f.left.device.timeoutTimer)
        f.advance(20_100)
        // Simulate a TimerTask that had already escaped cancel(); the phase epoch rejects it.
        f.ordinaryTimerTasks.first().run()
        assertEquals(BleConnectState.START_BINDING, f.left.device.connectState)
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.advance(21_000)
        // Deliver the real receiver callback; the cancelled phase timer must remain inert.
        f.resume(f.left)
        assertEquals(BleConnectState.SEARCH_SERVICE, f.left.device.connectState)
        assertNotNull(f.left.device.timeoutTimer)
        f.advance(30_000)
        Mockito.verify(f.left.gatt, Mockito.times(1)).discoverServices()
    }

    @Test
    fun `duplicate real connected callback retains bond timer and discovery guard`() = fixture { f ->
        f.foreground(f.left)
        f.contact(f.left)
        val deadline = f.deadlines.single()
        f.contact(f.left)
        assertEquals(1, f.deadlines.size)
        assertFalse(deadline.cancelled)
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.advance(30_000)
        f.contact(f.left)
        f.resume(f.left)
        Mockito.verify(f.left.gatt, Mockito.times(1)).discoverServices()
    }

    @Test
    fun `deadline rechecks BONDED before delayed broadcast and resumes exactly once`() = fixture { f ->
        f.foreground(f.left)
        f.contact(f.left)
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.advance(30_000)
        f.resume(f.left)
        Mockito.verify(f.left.gatt, Mockito.times(1)).discoverServices()
        assertEquals(BleConnectState.SEARCH_SERVICE, f.left.device.connectState)
    }

    @Test
    fun `thirty seconds still bonding terminates once and late success stays stale`() = fixture { f ->
        f.foreground(f.left)
        f.contact(f.left)
        f.left.bond = BluetoothDevice.BOND_BONDING
        val oldDeadline = f.deadlines.single().run
        f.advance(30_000)
        assertEquals(BleConnectState.BOUND_FAIL, f.left.device.connectState)
        assertNull(f.left.device.myGatt)
        oldDeadline()
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.resume(f.left)
        Mockito.verify(f.left.gatt, Mockito.never()).discoverServices()
        Mockito.verify(f.left.gatt, Mockito.times(1)).close()
    }

    @Test
    fun `cancelled queued leg and old deadline cannot open GATT after reset`() = fixture { f ->
        f.foreground(f.left)
        f.contact(f.left)
        val oldDeadline = f.deadlines.single().run
        f.foreground(f.right)
        f.manager.disconnect(f.right.uuid)
        f.manager.cleanConnectCache()
        oldDeadline()
        assertEquals(listOf(f.left.uuid), f.opened)
        assertTrue(f.pendingStarts().isEmpty())
    }

    @Test
    fun `supervisor activation queues before GATT and cancellation cannot revive deferred task`() = fixture { f ->
        val supervisor = f.supervisor()
        supervisor.activate(f.left.device, BleConnectSource.MANUAL_RECONNECT, sessionGeneration = 201L)
        val right = supervisor.activate(f.right.device, BleConnectSource.MANUAL_RECONNECT, sessionGeneration = 201L)
        assertEquals(BleReconnectOwnerDisposition.DEFERRED, right.ownerDisposition)
        assertEquals(listOf(f.left.uuid), f.opened)
        assertNull(f.right.device.myGatt)
        supervisor.activate(f.right.device, BleConnectSource.MANUAL_RECONNECT, sessionGeneration = 201L)
        assertEquals(listOf(f.left.uuid), f.opened)
        supervisor.cancel(f.right.uuid)
        f.manager.disconnect(f.left.uuid)
        assertEquals(listOf(f.left.uuid), f.opened)
        assertTrue(f.pendingStarts().isEmpty())
    }

    @Test
    fun `prephysical recycle closes old GATT before granting queued opener`() = fixture { f ->
        f.foreground(f.left)
        f.foreground(f.right)
        f.invoke("invalidatePendingPassiveGatt", f.left.uuid, f.left.gatt)
        assertEquals(listOf(f.left.uuid, "closed:${f.left.uuid}", f.right.uuid), f.timeline)
    }

    @Test
    fun `already bonded endpoints retain concurrent physical pending behavior`() = fixture { f ->
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.right.bond = BluetoothDevice.BOND_BONDED
        f.foreground(f.left)
        f.foreground(f.right)
        assertEquals(listOf(f.left.uuid, f.right.uuid), f.opened)
        assertTrue(f.pendingStarts().isEmpty())
    }

    @Test
    fun `Temp exact commit leaves retry with Dart until whole pair handoff`() = fixture { f ->
        f.foreground(f.left, 501L)
        f.foreground(f.right, 502L)
        f.contact(f.left)
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.resume(f.left)
        val first = f.readyForBusiness(f.left)
        assertEquals(BleBusinessConnectionStatus.ACCEPTED, f.manager.prepareBusinessConnection(first))

        // Exercise the actual channel decoder and exact native commit, rather than
        // proving only a policy helper. One connected leg must still release Gate.
        assertEquals("accepted", f.commitViaChannel(first, armAutoReconnect = false))
        assertEquals(BleConnectState.CONNECTED, f.left.device.connectState)
        assertFalse(f.hasOwner(f.left))
        assertEquals(listOf(f.left.uuid, f.right.uuid), f.opened)
        val connected = f.payloads().last {
            it["uuid"] == f.left.uuid && it["connectState"] == "connected"
        }
        assertEquals(first.sessionGeneration, connected["sessionGeneration"])
        assertEquals(first.attemptGeneration, connected["attemptGeneration"])

        f.contact(f.right)
        assertEquals(BleConnectState.START_BINDING, f.right.device.connectState)
        f.disconnectFromSystem(f.left)
        // No supervisor task means the real terminal schedule cannot open a
        // competing passive GATT while the other leg waits for Bond.
        assertEquals(listOf(f.left.uuid, f.right.uuid), f.opened)
        assertFalse(f.hasOwner(f.left))
        f.foreground(f.left, 503L)
        val retry = f.admission(f.left)
        assertEquals(503L, retry.sessionGeneration)
        assertTrue(retry.generation > first.attemptGeneration)
        assertEquals(listOf(f.left.uuid, f.right.uuid, f.left.uuid), f.opened)
        f.contact(f.left)

        f.right.bond = BluetoothDevice.BOND_BONDED
        f.resume(f.right)
        val right = f.readyForBusiness(f.right)
        assertEquals(BleBusinessConnectionStatus.ACCEPTED, f.manager.prepareBusinessConnection(right))
        assertEquals("accepted", f.commitViaChannel(right, armAutoReconnect = false))
        val left = f.readyForBusiness(f.left)
        assertEquals(BleBusinessConnectionStatus.ACCEPTED, f.manager.prepareBusinessConnection(left))
        assertEquals("accepted", f.commitViaChannel(left, armAutoReconnect = false))
        assertTrue(f.left.device.isConnected && f.right.device.isConnected)
        assertFalse(f.hasOwner(f.left) || f.hasOwner(f.right))

        // The existing formal handoff can now seed both durable targets without
        // reopening either live GATT or changing the accepted foreground pair.
        f.manager.armAutoReconnectTargets(listOf(f.seed(f.left), f.seed(f.right)))
        assertTrue(f.hasOwner(f.left) && f.hasOwner(f.right))
        assertEquals(listOf(f.left.uuid, f.right.uuid, f.left.uuid), f.opened)
    }

    @Test
    fun `omitted and explicit true business commit keep native reconnect enabled`() {
        listOf<Boolean?>(null, true).forEach { arm -> fixture { f ->
            f.left.bond = BluetoothDevice.BOND_BONDED
            f.foreground(f.left, 601L)
            f.contact(f.left)
            val attempt = f.readyForBusiness(f.left)
            assertEquals(BleBusinessConnectionStatus.ACCEPTED, f.manager.prepareBusinessConnection(attempt))
            assertEquals("accepted", f.commitViaChannel(attempt, arm))
            assertTrue(f.hasOwner(f.left))
            f.disconnectFromSystem(f.left)
            assertEquals(listOf(f.left.uuid, f.left.uuid), f.opened)
        } }
    }

    @Test
    fun `Temp arm opt out cannot commit a stale token or consume the current lease`() = fixture { f ->
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.foreground(f.left, 701L)
        f.contact(f.left)
        val current = f.readyForBusiness(f.left)
        assertEquals(BleBusinessConnectionStatus.ACCEPTED, f.manager.prepareBusinessConnection(current))
        val stale = current.copy(sessionGeneration = current.sessionGeneration - 1)
        assertEquals("attemptMismatch", f.commitViaChannel(stale, armAutoReconnect = false))
        assertFalse(f.left.device.isConnected)
        assertFalse(f.hasOwner(f.left))
        assertEquals(current.sessionGeneration, f.admission(f.left).sessionGeneration)
        assertEquals("accepted", f.commitViaChannel(current, armAutoReconnect = false))
        assertTrue(f.left.device.isConnected)
    }

    @Test
    fun `legacy business connected still arms native reconnect by default`() = fixture { f ->
        f.left.bond = BluetoothDevice.BOND_BONDED
        f.foreground(f.left, 801L)
        f.contact(f.left)
        f.readyForBusiness(f.left)
        f.manager.setPreConnected(f.left.uuid)
        assertEquals(BleBusinessConnectionStatus.ACCEPTED, f.manager.setConnected(f.left.uuid))
        assertTrue(f.hasOwner(f.left))
    }

    private fun fixture(test: (Fixture) -> Unit) {
        Mockito.mockStatic(Log::class.java).use {
            Mockito.mockStatic(SystemClock::class.java).use { clock ->
                clock.`when`<Long> { SystemClock.elapsedRealtime() }.thenReturn(1_000L)
                val payloads = IdentityHashMap<Any, MutableMap<String, Any?>>()
                val timerTasks = mutableListOf<TimerTask>()
                // Android's JSON is a stub in local tests; capture real production put calls.
                val jsonSettings = Mockito.withSettings().defaultAnswer { call ->
                    when (call.method.name) {
                        "put" -> {
                            payloads[call.mock]!![call.arguments[0] as String] = call.arguments[1]
                            call.mock
                        }
                        "toString" -> "{}"
                        else -> Mockito.RETURNS_DEFAULTS.answer(call)
                    }
                }
                Mockito.mockConstruction(JSONObject::class.java, jsonSettings) { json, _ ->
                    payloads[json] = linkedMapOf()
                }.use {
                    // Ordinary timers are captured so an already-running stale task can be
                    // delivered deterministically, without a real 20-second sleep.
                    Mockito.mockConstruction(Timer::class.java) { timer, _ ->
                        Mockito.doAnswer { call -> timerTasks += call.getArgument<TimerTask>(0); null }
                            .`when`(timer).schedule(Mockito.any(TimerTask::class.java), Mockito.anyLong())
                    }.use {
                        Fixture(timerTasks) { payloads.values.toList() }.use { fixture ->
                            test(fixture)
                            assertTrue(fixture.asyncErrors.isEmpty(), fixture.asyncErrors.toString())
                        }
                    }
                }
            }
        }
    }

    private class Fixture(
        val ordinaryTimerTasks: List<TimerTask>,
        val payloads: () -> List<Map<String, Any?>>,
    ) : AutoCloseable {
        val manager = BleManager.instance
        val adapter = Mockito.mock(BluetoothAdapter::class.java)
        val bluetooth = Mockito.mock(BluetoothManager::class.java)
        val opened = mutableListOf<String>()
        val timeline = mutableListOf<String>()
        // Authoritative Android connection queries track only delivered physical
        // callbacks; the Manager still owns admission and business transitions.
        val systemConnected = mutableListOf<BluetoothDevice>()
        var now = 0L
        // Async event delivery failures must fail the test instead of only printing to stderr.
        val asyncErrors = mutableListOf<Throwable>()
        data class Deadline(val at: Long, val run: () -> Unit, var cancelled: Boolean = false)
        val deadlines = mutableListOf<Deadline>()
        val oldScheduler: BleReconnectAttemptScheduler
        // Manager is process-wide; restore platform availability and scope for other test classes.
        val originalFields = listOf("mainScope", "weakContext", "bluetoothManager", "bleConfigs",
            "bleState", "blePermission", "bleLocation").associateWith { read<Any?>(it) }
        val config = BleConfig.empty().copy(
            name = "g2-pairing", connectTimeout = 20_000.0, autoReconnect = true,
            androidBondTimeout = 30_000.0, androidSerializeUnbonded = true,
            privateServices = listOf(BlePrivateService("1800", "2A00", "2A01", 0)),
        )
        val left: Endpoint
        val right: Endpoint
        init {
            field("mainScope", CoroutineScope(Dispatchers.Unconfined + CoroutineExceptionHandler { _, error -> asyncErrors += error }))
            field("weakContext", null)
            manager.cleanConnectCache()
            // cleanConnectCache preserves device display rows; isolate the singleton fixture.
            devices().clear()
            oldScheduler = read("bondWaitScheduler")
            field("bondWaitScheduler", BleReconnectAttemptScheduler { delay, run ->
                val d = Deadline(now + delay, run)
                deadlines += d
                BleReconnectScheduleHandle { d.cancelled = true }
            })
            Mockito.`when`(adapter.isEnabled).thenReturn(true)
            Mockito.`when`(bluetooth.adapter).thenReturn(adapter)
            Mockito.`when`(bluetooth.getConnectedDevices(BluetoothProfile.GATT)).thenAnswer { systemConnected.toList() }
            field("bluetoothManager", bluetooth)
            field("bleConfigs", listOf(config))
            field("bleState", 5)
            field("blePermission", true)
            field("bleLocation", true)
            left = Endpoint("AA:BB:CC:DD:EE:81", "Even_G2_L")
            right = Endpoint("AA:BB:CC:DD:EE:82", "Even_G2_R")
        }
        inner class Endpoint(val uuid: String, val name: String) {
            var bond = BluetoothDevice.BOND_NONE
            val remote = Mockito.mock(BluetoothDevice::class.java)
            val gatt = Mockito.mock(BluetoothGatt::class.java)
            val device = BleDevice(config, name, uuid, "SN", 0, BleConnectState.NONE)
            var callback: BluetoothGattCallback? = null
            init {
                Mockito.`when`(adapter.getRemoteDevice(uuid)).thenReturn(remote)
                Mockito.`when`(remote.address).thenReturn(uuid)
                Mockito.`when`(remote.name).thenReturn(name)
                Mockito.`when`(remote.bondState).thenAnswer { bond }
                Mockito.`when`(remote.createBond()).thenReturn(true)
                Mockito.`when`(gatt.device).thenReturn(remote)
                Mockito.`when`(gatt.discoverServices()).thenReturn(true)
                Mockito.doAnswer { timeline += "closed:$uuid"; null }.`when`(gatt).close()
                Mockito.`when`(remote.connectGatt(
                    Mockito.nullable(Context::class.java), Mockito.anyBoolean(), Mockito.any(BluetoothGattCallback::class.java),
                )).thenAnswer { invocation ->
                    opened += uuid
                    timeline += uuid
                    callback = invocation.getArgument(2)
                    gatt
                }
                devices().add(device)
            }
        }
        fun foreground(e: Endpoint, session: Long = 100L) = manager.connect(
            config.name, e.uuid, e.name, "SN", directConnect = true, sessionGeneration = session,
        )
        fun contact(e: Endpoint) {
            if (!systemConnected.contains(e.remote)) systemConnected += e.remote
            e.callback!!.onConnectionStateChange(e.gatt, 0, BluetoothProfile.STATE_CONNECTED)
        }
        /** Deliver the real terminal callback so Manager must decide whether to schedule. */
        fun disconnectFromSystem(e: Endpoint) {
            systemConnected.remove(e.remote)
            e.callback!!.onConnectionStateChange(e.gatt, 0, BluetoothProfile.STATE_DISCONNECTED)
        }
        /** Fake only ATT readiness; prepare/commit still validate the real GATT/admission. */
        fun readyForBusiness(e: Endpoint): BleBusinessConnectionAttempt {
            e.device.update(e.gatt, 0, Mockito.mock(BluetoothGattCharacteristic::class.java),
                Mockito.mock(BluetoothGattCharacteristic::class.java))
            e.device.markNotifyReady(0)
            val current = admission(e)
            assertTrue(current.sessionGeneration > 0L && current.generation > 0L)
            return BleBusinessConnectionAttempt(e.uuid, current.sessionGeneration, current.generation)
        }
        /** Use the public bridge to cover missing/true/false payload decoding in production. */
        fun commitViaChannel(attempt: BleBusinessConnectionAttempt, armAutoReconnect: Boolean? = null): Any? {
            var status: Any? = null
            val result = Mockito.mock(MethodChannel.Result::class.java)
            Mockito.doAnswer { call -> status = call.getArgument<Any?>(0); null }
                .`when`(result).success(Mockito.any())
            val payload = mutableMapOf<String, Any>("uuid" to attempt.uuid,
                "sessionGeneration" to attempt.sessionGeneration, "attemptGeneration" to attempt.attemptGeneration)
            if (armAutoReconnect != null) payload["armAutoReconnect"] = armAutoReconnect
            BleMC.COMMIT_BUSINESS_CONNECTION.handle(Mockito.mock(Context::class.java), payload, result)
            return status
        }
        fun hasOwner(e: Endpoint) = supervisor().endpointsMatching(e.uuid, e.name).contains(e.uuid)
        fun seed(e: Endpoint) = BleReconnectSeed(config.name, e.uuid, e.name, "SN", 0)
        fun resume(e: Endpoint) {
            (invoke("createBleStateListener") as BluetoothStateCallback).onDeviceBondStateChanged(
                e.remote, BluetoothDevice.BOND_BONDED, BluetoothDevice.BOND_BONDING,
            )
        }
        fun admission(e: Endpoint) = read<MutableMap<String, BleConnectionAdmission>>("currentAdmissions")[e.uuid.lowercase()]!!
        fun advance(to: Long) {
            now = to
            deadlines.filter { !it.cancelled && it.at <= now }.toList().forEach { it.cancelled = true; it.run() }
        }
        fun devices() = read<MutableList<BleDevice>>("connectedDevices")
        fun pendingStarts() = read<MutableMap<Long, Any>>("pendingGattStarts")
        fun supervisor() = invoke("getAutoReconnectSupervisor") as BleAutoReconnectSupervisor
        fun invoke(name: String, vararg args: Any): Any? = BleManager::class.java.declaredMethods.single {
            it.name == name && it.parameterCount == args.size
        }.also { it.isAccessible = true }.invoke(manager, *args)
        @Suppress("UNCHECKED_CAST")
        fun <T> read(name: String): T = BleManager::class.java.getDeclaredField(name).also { it.isAccessible = true }.get(manager) as T
        fun field(name: String, value: Any?) = BleManager::class.java.getDeclaredField(name).also { it.isAccessible = true }.set(manager, value)
        override fun close() {
            manager.cleanConnectCache()
            devices().clear()
            field("bondWaitScheduler", oldScheduler)
            originalFields.forEach { (name, value) -> field(name, value) }
        }
    }
}
