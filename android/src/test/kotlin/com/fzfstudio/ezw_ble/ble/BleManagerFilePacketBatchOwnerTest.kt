package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import org.mockito.Mockito

/** Real Manager admission and MethodChannel routing, with only the Android OS write mocked. */
class BleManagerFilePacketBatchOwnerTest {
    @Test
    fun `method channel reserves native String rejects malformed identity and acknowledges exact cancel`() = fixture { f ->
        val context = Mockito.mock(Context::class.java)
        val begin = Result()
        BleMC.from("beginFilePacketBatch").handle(context, mapOf("uuid" to f.uuid), begin)
        val token = assertNotNull(begin.value as? String)
        val busy = Result()
        BleMC.BEGIN_FILE_PACKET_BATCH.handle(context, mapOf("uuid" to f.uuid), busy)
        assertEquals("file_write_busy", busy.code)
        val malformed = Result()
        BleMC.SEND_FILE_PACKET_BATCH.handle(context, mapOf("uuid" to f.uuid, "packets" to listOf(byteArrayOf(1)), "fileBatchToken" to 7), malformed)
        assertEquals("file_write_unavailable", malformed.code)
        val cancel = Result()
        BleMC.from("cancelFilePacketBatch").handle(context, mapOf("uuid" to f.uuid, "fileBatchToken" to token), cancel)
        assertEquals(true, cancel.value)
        val again = Result()
        BleMC.CANCEL_FILE_PACKET_BATCH.handle(context, mapOf("uuid" to f.uuid, "fileBatchToken" to token), again)
        assertEquals(false, again.value)
        assertEquals(0, f.writes)
    }

    @Test
    fun `admission failure retires unused owner but duplicate send cannot retire active owner`() = fixture { f ->
        val invalidType = f.begin()
        f.manager.sendFilePacketBatch(f.uuid, listOf(byteArrayOf(1)), psType = 1, fileBatchToken = invalidType) {
            assertEquals("file_write_unsupported", it?.code)
        }
        assertFalse(f.manager.cancelFilePacketBatch(f.uuid, invalidType))
        val empty = f.begin()
        f.manager.sendFilePacketBatch(f.uuid, emptyList(), fileBatchToken = empty) { assertEquals("file_write_unavailable", it?.code) }
        assertFalse(f.manager.cancelFilePacketBatch(f.uuid, empty))
        val gated = f.begin()
        f.upgrading += f.uuid
        f.send(gated, 2)
        assertEquals("file_write_unavailable", f.results.single()?.code)
        assertFalse(f.manager.cancelFilePacketBatch(f.uuid, gated))
        f.upgrading.clear()
        val active = f.begin()
        f.send(active, 3, 4)
        f.send(active, 9)
        assertEquals("file_write_unavailable", f.results.last()?.code)
        assertTrue(f.manager.cancelFilePacketBatch(f.uuid, active), "duplicate must leave active owner cancellable")
        assertEquals(1, f.writes)
    }

    @Test
    fun `invalid native channel frames or ps type retire only the identified unused reservation`() = fixture { f ->
        val context = Mockito.mock(Context::class.java)
        for (invalid in listOf(mapOf("packets" to listOf(byteArrayOf(1), "bad")), mapOf("psType" to "3", "packets" to listOf(byteArrayOf(1))))) {
            val token = f.begin()
            val result = Result()
            BleMC.SEND_FILE_PACKET_BATCH.handle(context, invalid + mapOf("uuid" to f.uuid, "fileBatchToken" to token), result)
            assertNotNull(result.code)
            assertFalse(f.manager.cancelFilePacketBatch(f.uuid, token))
        }
        assertEquals(0, f.writes)
    }

    @Test
    fun `same UUID replacement cannot receive reserved or queued old physical target`() = fixture { f ->
        val empty = f.begin()
        val replacement = Mockito.mock(BluetoothGatt::class.java)
        Mockito.`when`(replacement.writeCharacteristic(f.write)).thenReturn(true)
        f.device.update(replacement, BlePsType.FILE, f.write, f.read)
        f.manager.beginFilePacketBatch(f.uuid) { token, error ->
            assertNull(token, "a retained old queue cannot reserve for the replacement target")
            assertEquals("file_write_unavailable", error?.code)
        }
        f.send(empty, 1)
        assertEquals("file_write_unavailable", f.results.single()?.code)
        assertFalse(f.manager.cancelFilePacketBatch(f.uuid, empty))
        Mockito.verify(replacement, Mockito.never()).writeCharacteristic(f.write)

        // Real teardown retires the stale queue before a same-UUID connection reserves again.
        f.teardown()
        val current = f.begin()
        assertNotEquals(empty, current)
        f.send(current, 2, 3)
        f.device.update(f.gatt, BlePsType.FILE, f.write, f.read)
        f.callback()
        assertEquals("file_write_unavailable", f.results.last()?.code)
        Mockito.verify(replacement, Mockito.times(1)).writeCharacteristic(f.write)
        assertEquals(0, f.writes, "old queued tail must not jump back to the same-UUID replacement")
    }

    @Test
    fun `manager exact cancellation preserves legacy work and old callback barrier`() = fixture { f ->
        val owned = f.begin()
        f.send(owned, 1, 2)
        f.send(null, 7)
        assertTrue(f.manager.cancelFilePacketBatch(f.uuid, owned))
        val replacement = f.begin()
        f.send(replacement, 8)
        assertEquals(1, f.writes)
        assertEquals(listOf("file_write_cancelled"), f.results.map { it?.code })
        f.callback() // Drain old OS write; it may submit legacy, but cannot complete it.
        assertEquals(2, f.writes)
        assertEquals(1, f.results.size)
        f.callback()
        assertEquals(3, f.writes)
        assertEquals(listOf("file_write_cancelled", null), f.results.map { it?.code })
        f.callback()
        assertEquals(listOf("file_write_cancelled", null, null), f.results.map { it?.code })
    }

    @Test
    fun `physical teardown revokes an empty reservation without touching another endpoint`() = fixture { f ->
        val token = f.begin()
        f.teardown()
        assertFalse(f.manager.cancelFilePacketBatch(f.uuid, token))
        f.send(token, 1)
        assertEquals("file_write_unavailable", f.results.single()?.code)
        assertEquals(0, f.writes)
        val newToken = f.begin()
        assertNotEquals(token, newToken)
        assertFalse(f.manager.cancelFilePacketBatch("another-endpoint", newToken))
        assertTrue(f.manager.cancelFilePacketBatch(f.uuid, newToken))
    }

    private fun fixture(block: (Fixture) -> Unit) {
        Mockito.mockStatic(Log::class.java).use {
            Mockito.mockStatic(SystemClock::class.java).use { clock ->
                clock.`when`<Long> { SystemClock.elapsedRealtime() }.thenReturn(1000L)
                Fixture().use(block)
            }
        }
    }

    /** Save and restore singleton fields; all queue scheduling uses a private cancellable scope. */
    private class Fixture : AutoCloseable {
        val manager = BleManager.instance
        val uuid = "AA:BB:CC:DD:EE:F9"
        val gatt = Mockito.mock(BluetoothGatt::class.java)
        val write = Mockito.mock(BluetoothGattCharacteristic::class.java)
        val read = Mockito.mock(BluetoothGattCharacteristic::class.java)
        var writes = 0
        val results = mutableListOf<BleOtaWriteError?>()
        val upgrading = field<MutableList<String>>("upgradeDevices")
        private val devices = field<MutableList<BleDevice>>("connectedDevices")
        private val queues = field<MutableMap<String, BleAndroidOtaWriteQueue>>("fileWriteQueues")
        private val savedDevices = devices.toList()
        private val savedUpgrading = upgrading.toList()
        private val savedQueues = queues.toMap()
        private val savedFields = listOf("mainScope", "bleState", "blePermission", "bleLocation", "bleConfigs").associateWith { field<Any?>(it) }
        private val scope = CoroutineScope(Dispatchers.Unconfined)
        private val config = BleConfig.empty().copy(name = "file-owner-test", privateServices = listOf(BlePrivateService("00002760-08c2-11e1-9073-0e8ac72e5450")))
        val device = BleDevice(config, "file", uuid, "test", -50, BleConnectState.CONNECTED)

        init {
            devices.clear()
            upgrading.clear()
            queues.clear()
            set("mainScope", scope)
            set("bleState", 5)
            set("blePermission", true)
            set("bleLocation", true)
            set("bleConfigs", listOf(config))
            Mockito.`when`(write.properties).thenReturn(BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)
            Mockito.doAnswer { writes += 1; true }.`when`(gatt).writeCharacteristic(write)
            device.update(gatt, BlePsType.FILE, write, read)
            devices += device
        }

        fun begin(): String {
            var token: String? = null
            manager.beginFilePacketBatch(uuid) { value, error -> assertNull(error); token = value }
            return assertNotNull(token)
        }

        fun send(token: String?, vararg bytes: Int) = manager.sendFilePacketBatch(
            uuid, bytes.map { byteArrayOf(it.toByte()) }, fileBatchToken = token,
        ) { results += it }

        fun callback() = assertNotNull(queues[uuid.lowercase()]).onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")

        fun teardown() {
            BleManager::class.java.getDeclaredMethod("discardWriteQueuesForSession", String::class.java, String::class.java)
                .also { it.isAccessible = true }.invoke(manager, uuid, "physical teardown")
        }

        @Suppress("UNCHECKED_CAST")
        private fun <T> field(name: String): T = BleManager::class.java.getDeclaredField(name).also { it.isAccessible = true }.get(manager) as T

        private fun set(name: String, value: Any?) = BleManager::class.java.getDeclaredField(name).also { it.isAccessible = true }.set(manager, value)

        override fun close() {
            queues.values.toList().forEach { it.cancelAll("fixture teardown") }
            scope.cancel()
            queues.clear(); queues.putAll(savedQueues)
            devices.clear(); devices.addAll(savedDevices)
            upgrading.clear(); upgrading.addAll(savedUpgrading)
            savedFields.forEach { (name, value) -> set(name, value) }
        }
    }

    /** Capture the exact MethodChannel return type, not just source-code strings. */
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var code: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { code = errorCode }
        override fun notImplemented() = error("unexpected missing native method")
    }
}
