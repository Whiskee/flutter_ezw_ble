package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import org.mockito.Mockito

/** Real Manager-created queues must share its teardown lock, not acquire it in reverse. */
class BleManagerWriteQueueLockTest {
    @Test
    fun `FILE zero pair callback and manager teardown cannot deadlock`() =
        callbackVersusTeardown(BlePsType.FILE, 0L, 0L)

    @Test
    fun `OTA exact pair callback and manager teardown cannot deadlock`() =
        callbackVersusTeardown(BlePsType.OTA, 63L, 64L)

    @Test
    fun `shared lock still rejects changed exact pair before the queued OTA tail`() {
        Fixture(BlePsType.OTA, 63L, 64L).use { f ->
            f.queue.enqueueBatch(listOf(byteArrayOf(1), byteArrayOf(2)), 63L, 64L) { f.results += it }
            f.clearAdmission()
            f.callback()
            assertEquals(1, f.writes)
            assertEquals("ota_write_unavailable", f.results.single()?.code)
            assertEquals(0, f.queue.queueDepth)
        }
    }

    @Test
    fun `late callback from removed queue cannot settle a replacement file owner`() {
        Fixture(BlePsType.FILE, 0L, 0L).use { f ->
            f.queue.enqueueBatch(listOf(byteArrayOf(1), byteArrayOf(2))) { f.results += it }
            synchronized(f.manager) { f.cancelAllQueues() }
            val replacement = f.createQueue()
            val nextResults = mutableListOf<BleOtaWriteError?>()
            replacement.enqueueBatch(listOf(byteArrayOf(3))) { nextResults += it }
            f.callback()
            assertEquals(2, f.writes, "the old tail cannot reappear on the replacement queue")
            assertTrue(nextResults.isEmpty(), "old callbacks cannot complete the new native write")
            replacement.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")
            assertEquals(1, nextResults.size)
            assertNull(nextResults.single())
        }
    }

    @Test
    fun `watchdog uses the same monitor as admission and teardown`() {
        val monitor = Any()
        var scheduled: (() -> Unit)? = null
        var attempts = 0
        val queue = BleAndroidOtaWriteQueue(
            endpoint = "watchdog-lock",
            submit = { _, _, _, _, _, _ ->
                attempts += 1
                BleOtaWriteSubmission.busy(null, "OS busy")
            },
            scheduler = BleOtaWriteScheduler { _, block ->
                scheduled = block
                BleOtaWriteCancellable {}
            },
            nowMillis = { 0L },
            stateLock = monitor,
        )
        queue.enqueue(byteArrayOf(1)) {}
        val tick = checkNotNull(scheduled)
        val finished = CountDownLatch(1)
        lateinit var watchdog: Thread
        synchronized(monitor) {
            watchdog = thread(isDaemon = true) {
                try {
                    tick()
                } finally {
                    finished.countDown()
                }
            }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (watchdog.state != Thread.State.BLOCKED && finished.count > 0 &&
                System.nanoTime() < deadline
            ) {
                Thread.yield()
            }
            assertEquals(Thread.State.BLOCKED, watchdog.state, "timer cannot pump outside the manager lock")
            assertEquals(1, attempts)
        }
        assertTrue(finished.await(2, TimeUnit.SECONDS))
        assertEquals(2, attempts)
        queue.cancelAll("test teardown")
    }

    private fun callbackVersusTeardown(psType: Int, session: Long, attempt: Long) {
        Fixture(psType, session, attempt).use { f ->
            f.queue.enqueueBatch(listOf(byteArrayOf(1), byteArrayOf(2)), session, attempt) {
                f.results += it
            }
            assertEquals(1, f.writes, "the real identity and OS submission path must be reached")
            val managerHeld = CountDownLatch(1)
            val cancelMayStart = CountDownLatch(1)
            val cancelled = CountDownLatch(1)
            val callbackFinished = CountDownLatch(1)
            val failure = AtomicReference<Throwable?>()
            // A failed old implementation leaves only private daemon-owned objects blocked;
            // never poison the singleton Manager or hang the JVM after a regression failure.
            val teardown = thread(isDaemon = true, name = "write-queue-manager-teardown") {
                try {
                    synchronized(f.manager) {
                        managerHeld.countDown()
                        check(cancelMayStart.await(2, TimeUnit.SECONDS))
                        f.cancelAllQueues()
                    }
                    cancelled.countDown()
                } catch (error: Throwable) {
                    failure.set(error)
                }
            }
            assertTrue(managerHeld.await(2, TimeUnit.SECONDS))
            val callback = thread(isDaemon = true, name = "write-queue-gatt-callback") {
                try {
                    f.callback()
                } catch (error: Throwable) {
                    failure.set(error)
                } finally {
                    callbackFinished.countDown()
                }
            }
            // Freeze exactly after the callback is waiting for Manager. Before the repair it
            // already owns Queue; with one lock it cannot mutate Queue until teardown exits.
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (callback.state != Thread.State.BLOCKED && callbackFinished.count > 0 &&
                System.nanoTime() < deadline
            ) {
                Thread.yield()
            }
            val callbackStack = callback.stackTrace.joinToString("\n")
            val wasBlocked = callback.state == Thread.State.BLOCKED
            cancelMayStart.countDown()
            assertTrue(
                wasBlocked,
                "the competing callback must reach the held monitor before cancellation",
            )
            assertTrue(
                cancelled.await(2, TimeUnit.SECONDS),
                "Manager -> Queue and callback -> Manager must not form a lock cycle:\n$callbackStack",
            )
            assertTrue(callbackFinished.await(2, TimeUnit.SECONDS))
            failure.get()?.let { throw it }
            teardown.join(100)
            callback.join(100)
            val cancelledCode = if (psType == BlePsType.FILE) "file_write_cancelled" else "ota_write_cancelled"
            assertEquals(listOf(cancelledCode), f.results.map { it?.code })
            assertEquals(1, f.writes, "late callback cannot submit an already-cancelled tail")
            assertEquals(0, f.queue.queueDepth)
            assertFalse(f.queue.hasOutstandingGattWrite)
        }
    }

    /** A private real Manager keeps deliberately deadlocking red runs isolated from other tests. */
    private class Fixture(private val psType: Int, session: Long, attempt: Long) : AutoCloseable {
        val manager = BleManager::class.java.getDeclaredConstructor()
            .also { it.isAccessible = true }.newInstance()
        private val scope = CoroutineScope(Dispatchers.Unconfined)
        private val uuid = "AA:BB:CC:DD:EE:F6"
        private val gatt = Mockito.mock(BluetoothGatt::class.java)
        private val write = Mockito.mock(BluetoothGattCharacteristic::class.java)
        var writes = 0
        val results = mutableListOf<BleOtaWriteError?>()
        val queue: BleAndroidOtaWriteQueue

        init {
            set("mainScope", scope)
            set("bleState", 5)
            set("blePermission", true)
            set("bleLocation", true)
            Mockito.`when`(write.properties).thenReturn(BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)
            Mockito.doAnswer {
                writes += 1
                true
            }.`when`(gatt).writeCharacteristic(write)
            val config = BleConfig.empty().copy(
                name = "lock-test",
                privateServices = listOf(BlePrivateService("00002760-08c2-11e1-9073-0e8ac72e5450")),
            )
            set("bleConfigs", listOf(config))
            val device = BleDevice(config, "lock-test", uuid, "test", -50, BleConnectState.CONNECTED)
            device.update(gatt, psType, write, Mockito.mock(BluetoothGattCharacteristic::class.java))
            field<MutableList<BleDevice>>("connectedDevices") += device
            if (session > 0 && attempt > 0) {
                val admission = BleConnectionAdmission(
                    uuid, attempt, attempt, BleConnectSource.AUTO_RECONNECT, session,
                )
                field<MutableMap<String, BleConnectionAdmission>>("currentAdmissions")[uuid.lowercase()] = admission
                val businessType = Class.forName(
                    "com.fzfstudio.ezw_ble.ble.BleManager\$BusinessConnectedGattSession",
                )
                val business = businessType.declaredConstructors.first()
                    .also { it.isAccessible = true }.newInstance(admission, gatt)
                field<MutableMap<String, Any>>("businessConnectedGattSessions")[uuid.lowercase()] = business
            }
            queue = createQueue()
        }

        fun createQueue(): BleAndroidOtaWriteQueue {
            val method = if (psType == BlePsType.FILE) "fileWriteQueueFor" else "otaWriteQueueFor"
            return BleManager::class.java.getDeclaredMethod(method, String::class.java)
                .also { it.isAccessible = true }.invoke(manager, uuid) as BleAndroidOtaWriteQueue
        }

        fun clearAdmission() = field<MutableMap<String, BleConnectionAdmission>>("currentAdmissions").clear().also {
            field<MutableMap<String, Any>>("businessConnectedGattSessions").clear()
        }

        fun callback() = queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")

        fun cancelAllQueues() = BleManager::class.java
            .getDeclaredMethod("cancelAllWriteQueues", String::class.java)
            .also { it.isAccessible = true }.invoke(manager, "bluetoothOff")

        @Suppress("UNCHECKED_CAST")
        private fun <T> field(name: String): T = BleManager::class.java.getDeclaredField(name)
            .also { it.isAccessible = true }.get(manager) as T

        private fun set(name: String, value: Any) = BleManager::class.java.getDeclaredField(name)
            .also { it.isAccessible = true }.set(manager, value)

        override fun close() {
            scope.cancel()
        }
    }
}
