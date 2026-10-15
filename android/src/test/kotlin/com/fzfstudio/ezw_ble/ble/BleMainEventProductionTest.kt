package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.os.SystemClock
import com.fzfstudio.ezw_ble.ble.models.*
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlin.test.*
import org.mockito.Mockito

/** Drives the real failure producers, not a replacement for write/dequeue production code. */
class BleMainEventProductionTest {
    private class Fixture : AutoCloseable {
        val manager = BleManager.instance
        val posts = ArrayDeque<Runnable>()
        val events = mutableListOf<Pair<BleEC, Any>>()
        private val scope = CoroutineScope(Job() + Dispatchers.Unconfined)
        private val priorScope = get("mainScope")
        private val priorOutbox = get("mainEventOutbox")
        private val priorWarning = get("lastOutboxDelayWarningAt")
        val outbox = BleMainEventOutbox(
            post = { posts.addLast(it) }, nowMillis = { 0 },
            deliver = { channel, payload -> events.add(channel to payload) },
        )
        init {
            set("mainScope", scope)
            set("mainEventOutbox", outbox)
            set("lastOutboxDelayWarningAt", null)
        }
        fun drain() { while (posts.isNotEmpty()) posts.removeFirst().run() }
        fun get(name: String): Any? = BleManager::class.java.getDeclaredField(name)
            .also { it.isAccessible = true }.get(manager)
        fun set(name: String, value: Any?) = BleManager::class.java.getDeclaredField(name)
            .also { it.isAccessible = true }.set(manager, value)
        override fun close() {
            outbox.release()
            scope.cancel()
            set("mainScope", priorScope)
            set("mainEventOutbox", priorOutbox)
            set("lastOutboxDelayWarningAt", priorWarning)
        }
    }

    @Test
    fun `missing readiness failure is queued and retains original identity`() = Fixture().use { f ->
        val device = device()
        // Execute exactly as a binder callback would: no Flutter sink may be called here.
        val write = java.util.concurrent.FutureTask {
            assertFalse(device.writeCharacteristic(byteArrayOf(1), 0, 7, 11))
        }
        Thread(write).start()
        write.get(3, java.util.concurrent.TimeUnit.SECONDS)
        assertTrue(f.events.isEmpty())
        assertEquals(1, f.posts.size)
        f.drain()
        assertFailure(f.events.single(), 0)
    }

    @Test
    fun `gatt write rejection is queued instead of invoking Flutter on binder thread`() = Fixture().use { f ->
        val device = device()
        val gatt = Mockito.mock(BluetoothGatt::class.java)
        val characteristic = Mockito.mock(BluetoothGattCharacteristic::class.java)
        device.update(gatt, 0, characteristic, characteristic)
        assertFalse(device.writeCharacteristic(byteArrayOf(1), 0, 7, 11))
        Mockito.verify(gatt).writeCharacteristic(characteristic)
        assertTrue(f.events.isEmpty())
        f.drain()
        assertFailure(f.events.single(), 0)
    }

    @Test
    fun `both synchronous write failures let the real binder dequeue advance`() {
        listOf(false, true).forEach { installRejectedCharacteristic -> Fixture().use { f ->
            val device = device()
            val gatt = Mockito.mock(BluetoothGatt::class.java)
            val rejected = Mockito.mock(BluetoothGattCharacteristic::class.java)
            val accepted = Mockito.mock(BluetoothGattCharacteristic::class.java)
            // The first iteration has no type=0 characteristic; the second has one
            // but GATT refuses its write. Both must drop only that queue head.
            if (installRejectedCharacteristic) device.update(gatt, 0, rejected, rejected)
            device.update(gatt, 3, accepted, accepted)
            Mockito.`when`(gatt.writeCharacteristic(accepted)).thenReturn(true)
            @Suppress("UNCHECKED_CAST")
            val devices = f.get("connectedDevices") as MutableList<BleDevice>
            @Suppress("UNCHECKED_CAST")
            val queues = f.get("sendCmdQueues") as MutableMap<String, ConcurrentLinkedQueue<BleCmd>>
            val first = BleCmd(device.uuid, 0, byteArrayOf(1), true, 7, 11)
            val next = BleCmd(device.uuid, 3, byteArrayOf(2), true)
            val key = device.uuid.lowercase()
            val priorQueue = queues.put(key, ConcurrentLinkedQueue(listOf(first, next)))
            devices.add(device)
            try {
                val dequeue = java.util.concurrent.FutureTask {
                    BleManager::class.java.getDeclaredMethod("writeNextCommand", String::class.java)
                        .also { it.isAccessible = true }.invoke(f.manager, device.uuid)
                }
                Thread(dequeue).start()
                dequeue.get(3, java.util.concurrent.TimeUnit.SECONDS)
                assertSame(next, queues[key]?.peek())
                Mockito.verify(gatt).writeCharacteristic(accepted)
                assertTrue(f.events.isEmpty())
                f.drain()
                assertFailure(f.events.first { it.first == BleEC.RECEIVE_DATA }, 0)
            } finally {
                devices.remove(device)
                if (priorQueue == null) queues.remove(key) else queues[key] = priorQueue
            }
        } }
    }

    @Test
    fun `ota identity mismatch emits typed original failure and advances the real native queue`() = Fixture().use { f ->
        val device = device()
        val gatt = Mockito.mock(BluetoothGatt::class.java)
        val characteristic = Mockito.mock(BluetoothGattCharacteristic::class.java)
        device.update(gatt, 0, characteristic, characteristic)
        Mockito.`when`(gatt.writeCharacteristic(characteristic)).thenReturn(true)
        @Suppress("UNCHECKED_CAST")
        val devices = f.get("connectedDevices") as MutableList<BleDevice>
        @Suppress("UNCHECKED_CAST")
        val queues = f.get("sendCmdQueues") as MutableMap<String, ConcurrentLinkedQueue<BleCmd>>
        val stale = BleCmd(device.uuid, 1, byteArrayOf(1), true,
            sessionGeneration = 7, attemptGeneration = 11,
            otaTransactionId = "retired", otaGeneration = 2, otaInstanceId = "old-instance")
        val next = BleCmd(device.uuid, 0, byteArrayOf(2), true)
        val key = device.uuid.lowercase()
        val priorQueue = queues.put(key, ConcurrentLinkedQueue(listOf(stale, next)))
        devices.add(device)
        try {
            BleManager::class.java.getDeclaredMethod("writeNextCommand", String::class.java)
                .also { it.isAccessible = true }.invoke(f.manager, device.uuid)
            assertSame(next, queues[key]?.peek())
            Mockito.verify(characteristic).setValue(byteArrayOf(2))
            Mockito.verify(gatt).writeCharacteristic(characteristic)
            assertTrue(f.events.isEmpty())
            f.drain()
            val failure = f.events.first { it.first == BleEC.RECEIVE_DATA }
            assertFailure(failure, 1)
            @Suppress("UNCHECKED_CAST")
            val map = failure.second as Map<String, Any?>
            assertEquals("retired", map["otaTransactionId"])
            assertEquals("old-instance", map["otaInstanceId"])
        } finally {
            devices.remove(device)
            if (priorQueue == null) queues.remove(key) else queues[key] = priorQueue
        }
    }

    @Test
    fun `slow drain warning uses existing error prefix and five second rate limit`() = Fixture().use { f ->
        var now = 100L
        val report = BleManager::class.java.getDeclaredMethod(
            "logOutboxDelay", Long::class.javaPrimitiveType,
            Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
        ).also { it.isAccessible = true }
        Mockito.mockStatic(SystemClock::class.java).use { clock ->
            clock.`when`<Long> { SystemClock.elapsedRealtime() }.thenAnswer { now }
            report.invoke(f.manager, 200L, 4, 7)
            assertTrue(f.posts.isEmpty())
            report.invoke(f.manager, 201L, 4, 7)
            now += 4_999
            report.invoke(f.manager, 999L, 2, 3)
            now++
            report.invoke(f.manager, 202L, 2, 3)
            f.drain()
            assertEquals(2, f.events.size)
            assertTrue(f.events.all { it.first == BleEC.LOGGER && (it.second as String).startsWith("[e]-BleManager::") })
            assertTrue((f.events.first().second as String).contains("delayMs=201, sent=4, remaining=7"))
        }
    }

    @Test
    fun `released scope prevents failure producers from enqueueing`() = Fixture().use { f ->
        (f.get("mainScope") as CoroutineScope).cancel()
        device().writeCharacteristic(byteArrayOf(1), 0, 7, 11)
        assertTrue(f.posts.isEmpty())
        assertTrue(f.events.isEmpty())
    }

    @Test
    fun `real callback retains old event lifetime when binder delivery resumes after replacement`() = Fixture().use { f ->
        val endpoint = "AA:BB:CC:DD:EE:96"
        val callback = BleManager::class.java.getDeclaredMethod(
            "createConnectCallBack", String::class.java, BleConnectSource::class.java,
            Boolean::class.javaPrimitiveType, Long::class.javaPrimitiveType,
        ).also { it.isAccessible = true }.invoke(f.manager, endpoint, BleConnectSource.AUTO_RECONNECT, false, 7L)
        @Suppress("UNCHECKED_CAST")
        val receive = BleGattSessionCallback::class.java.getDeclaredField("emitReceiveData")
            .also { it.isAccessible = true }.get(callback) as (Map<String, Any?>) -> Unit
        @Suppress("UNCHECKED_CAST")
        val logger = BleGattSessionCallback::class.java.getDeclaredField("sendLog")
            .also { it.isAccessible = true }.get(callback) as (com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag, String) -> Unit
        val freshPosts = ArrayDeque<Runnable>()
        val freshEvents = mutableListOf<Any>()
        val freshOutbox = BleMainEventOutbox(
            post = { freshPosts.addLast(it) }, nowMillis = { 0 },
            deliver = { _, payload -> freshEvents.add(payload) },
        )
        try {
            // Resume the real output closures after the old payload/identity has
            // already been frozen; callback admission itself is covered separately.
            f.outbox.release()
            f.set("mainEventOutbox", freshOutbox)
            receive(mapOf("uuid" to endpoint, "sessionGeneration" to 7L))
            logger(com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag.d, "old callback")
            assertTrue(freshPosts.isEmpty())
            val fresh = mapOf("uuid" to "fresh")
            f.manager.emitReceiveData(fresh)
            freshPosts.removeFirst().run()
            assertEquals(listOf<Any>(fresh), freshEvents)
            f.drain()
            assertTrue(f.events.isEmpty())
        } finally {
            freshOutbox.release()
            @Suppress("UNCHECKED_CAST")
            (f.get("currentAdmissions") as MutableMap<String, Any>).remove(endpoint.lowercase())
            @Suppress("UNCHECKED_CAST")
            (f.get("connectionAttemptGenerations") as MutableMap<String, Any>).remove(endpoint.lowercase())
            val gate = f.get("connectionAdmissionGate")!!
            @Suppress("UNCHECKED_CAST")
            (BleConnectionAdmissionGate::class.java.getDeclaredField("latestGenerations")
                .also { it.isAccessible = true }.get(gate) as MutableMap<String, Any>).remove(endpoint.lowercase())
        }
    }

    private fun device() = BleDevice(
        BleConfig.empty().copy(privateServices = listOf(BlePrivateService(UUID.randomUUID().toString()))),
        "R1", "AA:BB:CC:DD:EE:98", "sn", 0, BleConnectState.CONNECTED,
    )

    private fun assertFailure(event: Pair<BleEC, Any>, psType: Int) {
        assertEquals(BleEC.RECEIVE_DATA, event.first)
        @Suppress("UNCHECKED_CAST")
        val map = event.second as Map<String, Any?>
        assertEquals(false, map["isSuccess"])
        assertEquals(psType, map["psType"])
        assertEquals(7L, map["sessionGeneration"])
        assertEquals(11L, map["attemptGeneration"])
        assertNull(map["data"])
    }
}
