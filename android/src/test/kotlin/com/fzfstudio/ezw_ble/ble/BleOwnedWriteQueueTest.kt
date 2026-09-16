package com.fzfstudio.ezw_ble.ble

import android.bluetooth.*
import com.fzfstudio.ezw_ble.ble.models.*
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlin.test.*
import org.mockito.Mockito
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.UUID

/** Exercises the manager's real dequeue and BleDevice's real GATT submission. */
class BleOwnedWriteQueueTest {
    @Test
    fun `malformed supplied channel intent fails before manager enqueue`() {
        val context = Mockito.mock(android.content.Context::class.java)
        val malformed = listOf(null, mapOf("uuid" to "ring"),
            mapOf("uuid" to "ring", "sessionGeneration" to 7.5, "attemptGeneration" to 1),
            mapOf("uuid" to "other", "sessionGeneration" to 7, "attemptGeneration" to 1))
        malformed.forEach { expected ->
            val result = Mockito.mock(io.flutter.plugin.common.MethodChannel.Result::class.java)
            BleMC.SEND_CMD.handle(context, mapOf("uuid" to "ring", "data" to byteArrayOf(1),
                "expectedAttempt" to expected), result)
            Mockito.verify(result).error("owned_write_invalid_arguments", "Invalid expected BLE attempt", null)
            Mockito.verify(result, Mockito.never()).success(Mockito.any())
        }
    }

    @Test
    fun `queued old attempt is dropped while replacement and legacy writes survive`() {
        val manager = BleManager.instance
        val uuid = "AA:BB:CC:DD:EE:99"
        val gatt = Mockito.mock(BluetoothGatt::class.java)
        val peripheral = Mockito.mock(BluetoothDevice::class.java)
        val characteristic = Mockito.mock(BluetoothGattCharacteristic::class.java)
        Mockito.`when`(gatt.device).thenReturn(peripheral)
        Mockito.`when`(peripheral.address).thenReturn(uuid)
        Mockito.`when`(gatt.writeCharacteristic(characteristic)).thenReturn(true)
        val config = BleConfig.empty().copy(privateServices = listOf(BlePrivateService(UUID.randomUUID().toString())))
        val device = BleDevice(config, "R1", uuid, "sn", 0, BleConnectState.CONNECTED)
        device.update(gatt, 0, characteristic, characteristic)
        val devices = field<MutableList<BleDevice>>(manager, "connectedDevices")
        val sessions = field<MutableMap<String, Any>>(manager, "businessConnectedGattSessions")
        val queues = field<MutableMap<String, ConcurrentLinkedQueue<BleCmd>>>(manager, "sendCmdQueues")
        val admission = BleConnectionAdmission(uuid, 2, 22, BleConnectSource.AUTO_RECONNECT, 7)
        val ctor = Class.forName("com.fzfstudio.ezw_ble.ble.BleManager\$BusinessConnectedGattSession").declaredConstructors.first().also { it.isAccessible = true }
        devices.add(device)
        val priorState = field<Int>(manager, "bleState")
        val priorConfigs = field<List<BleConfig>>(manager, "bleConfigs")
        val priorPermission = field<Boolean>(manager, "blePermission")
        val priorLocation = field<Boolean>(manager, "bleLocation")
        setField(manager, "bleState", 5)
        setField(manager, "bleConfigs", listOf(config))
        setField(manager, "blePermission", true)
        setField(manager, "bleLocation", true)
        sessions[uuid.lowercase()] = ctor.newInstance(admission.copy(generation = 1), gatt)
        // A preceding in-flight write holds the actual manager queue. Enqueue A
        // through the public manager path before replacing its retained attempt.
        val queue = ConcurrentLinkedQueue(listOf(BleCmd(uuid, 0, byteArrayOf(0), false)))
        queues[uuid.lowercase()] = queue
        val dequeue = BleManager::class.java.getDeclaredMethod("writeNextCommand", String::class.java).also { it.isAccessible = true }
        try {
            manager.sendCmd(uuid, byteArrayOf(1), expectedAttempt = BleBusinessConnectionAttempt(uuid, 7, 1))
            sessions[uuid.lowercase()] = ctor.newInstance(admission, gatt)
            manager.sendCmd(uuid, byteArrayOf(2), expectedAttempt = BleBusinessConnectionAttempt(uuid, 7, 2))
            val fresh = queue.last()
            queue.poll() // Release the earlier in-flight write.
            assertEquals(BleBusinessConnectionAttempt(uuid, 7, 2), manager.captureReceiveIdentity(gatt))
            dequeue.invoke(manager, uuid)
            assertSame(fresh, queue.peek())
            Mockito.verify(characteristic).setValue(byteArrayOf(2))
            Mockito.verify(gatt, Mockito.times(1)).writeCharacteristic(characteristic)
            queue.poll()
            manager.sendCmd(uuid, byteArrayOf(3))
            Mockito.verify(characteristic).setValue(byteArrayOf(3))
            assertFailsWith<IllegalArgumentException> {
                manager.sendCmd(uuid, byteArrayOf(4), expectedAttempt = BleBusinessConnectionAttempt(uuid, 0, 2))
            }
            assertFailsWith<IllegalArgumentException> {
                manager.sendCmd(uuid, byteArrayOf(4), expectedAttempt = BleBusinessConnectionAttempt("other", 7, 2))
            }
            sessions.remove(uuid.lowercase())
            assertNull(manager.captureReceiveIdentity(gatt))
        } finally {
            devices.remove(device)
            sessions.remove(uuid.lowercase())
            queues.remove(uuid.lowercase())
            setField(manager, "bleState", priorState)
            setField(manager, "bleConfigs", priorConfigs)
            setField(manager, "blePermission", priorPermission)
            setField(manager, "bleLocation", priorLocation)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> field(manager: BleManager, name: String): T =
        BleManager::class.java.getDeclaredField(name).also { it.isAccessible = true }.get(manager) as T

    private fun setField(manager: BleManager, name: String, value: Any) {
        BleManager::class.java.getDeclaredField(name).also { it.isAccessible = true }.set(manager, value)
    }
}
