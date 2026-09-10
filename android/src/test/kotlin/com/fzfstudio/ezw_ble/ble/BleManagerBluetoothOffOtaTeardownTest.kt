package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.os.SystemClock
import android.util.Log
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import java.lang.ref.WeakReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.mockito.Mockito

/** 蓝牙 OFF 必须走真实 Manager 入口清掉已失效 GATT session 的 OTA 写状态。 */
class BleManagerBluetoothOffOtaTeardownTest {

    @Test
    fun `bluetooth off freezes physical disconnect before exact owner teardown`() {
        val manager = BleManager.instance
        setWeakContext(manager, null)
        manager.cleanConnectCache()
        val endpoint = "AA:BB:CC:DD:EE:20"
        val devices = managerField<MutableList<BleDevice>>(manager, "connectedDevices")
        devices += BleDevice(
            belongConfig = BleConfig.empty().copy(name = "g2", autoReconnect = true),
            name = "Even G2_L_test",
            uuid = endpoint,
            sn = "SN",
            rssi = 0,
            connectState = BleConnectState.CONNECTED,
        )
        registerAttempt(manager, endpoint)

        Mockito.mockStatic(Log::class.java).use {
            Mockito.mockStatic(SystemClock::class.java).use { clock ->
                clock.`when`<Long> { SystemClock.elapsedRealtime() }.thenReturn(1000L)
                try {
                    manager.setConnectionTraceEnabled(true)
                    invokePrivate(manager, "startNativeTrace", endpoint)
                    invokePrivate(
                        manager,
                        "captureBluetoothOffTerminalSnapshots",
                        true,
                    )

                    val traces = managerField<MutableMap<String, Any>>(manager, "nativeConnectionTraces")
                    val buffer = traces[endpoint.lowercase()]!!
                    val steps = privateField<List<Any>>(buffer, "steps")
                    val disconnects = steps.filter { step ->
                        privateField<String?>(step, "physicalConnectionEvent") == "disconnected"
                    }
                    assertEquals(1, disconnects.size)
                    assertTrue(privateField<Long>(disconnects.single(), "occurredAtMs") > 0L)
                    assertEquals(
                        "valid",
                        privateField<String>(disconnects.single(), "timingStatus"),
                    )
                } finally {
                    invokeBluetoothStateChanged(manager, BluetoothAdapter.STATE_ON)
                    manager.setConnectionTraceEnabled(false)
                    devices.clear()
                    setWeakContext(manager, null)
                }
            }
        }
    }

    @Test
    fun `bluetooth off cancels accepted ota write before clearing upgrade marker`() {
        val manager = BleManager.instance
        setWeakContext(manager, null)
        manager.cleanConnectCache()
        val endpoint = "AA:BB:CC:DD:EE:FF"
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = BleAndroidOtaWriteQueue(
            endpoint = endpoint,
            submit = { _, _, _, _, _, _ -> BleOtaWriteSubmission.accepted() },
            scheduler = BleOtaWriteScheduler { _, _ -> BleOtaWriteCancellable {} },
            nowMillis = { 0L },
        )
        queue.enqueue(byteArrayOf(0x01)) { completions.add(it) }

        otaWriteQueues(manager)[endpoint.lowercase()] = queue
        upgradeDevices(manager).add(endpoint)

        Mockito.mockStatic(Log::class.java).use {
            try {
                // Hostile timeline: RAW 已被 Android 接受但 callback 未返回，此时关闭蓝牙。
                invokeBluetoothStateChanged(manager, BluetoothAdapter.STATE_OFF)

                assertEquals("ota_write_cancelled", completions.single()?.code)
                assertTrue(otaWriteQueues(manager).isEmpty())
                assertTrue(upgradeDevices(manager).isEmpty())
                assertEquals(0, queue.queueDepth)
                assertTrue(!queue.hasOutstandingGattWrite)
            } finally {
                // 单例 Manager 供同一 JVM 的其它测试复用，恢复 Gate/蓝牙状态避免跨测试污染。
                invokeBluetoothStateChanged(manager, BluetoothAdapter.STATE_ON)
                setWeakContext(manager, null)
            }
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

    /** 测试不需要 Android Context；显式清空避免单例 Manager 继承其它测试的 mock。 */
    private fun setWeakContext(manager: BleManager, context: WeakReference<android.content.Context>?) {
        val field = BleManager::class.java.getDeclaredField("weakContext")
        field.isAccessible = true
        field.set(manager, context)
    }

    private fun invokeBluetoothStateChanged(manager: BleManager, state: Int) {
        invokePrivate(manager, "handleBluetoothStateChanged", state)
    }

    private fun registerAttempt(manager: BleManager, endpoint: String): BleConnectionAdmission =
        invokePrivate(
            manager,
            "registerConnectionAttempt",
            endpoint,
            BleConnectSource.AUTO_RECONNECT,
            0L,
        ) as BleConnectionAdmission

    private fun invokePrivate(manager: BleManager, name: String, vararg args: Any): Any? {
        val parameterTypes = args.map { value ->
            when (value) {
                is Int -> Int::class.javaPrimitiveType
                is Long -> Long::class.javaPrimitiveType
                is Boolean -> Boolean::class.javaPrimitiveType
                else -> value::class.java
            }
        }.toTypedArray()
        return BleManager::class.java.getDeclaredMethod(name, *parameterTypes)
            .also { it.isAccessible = true }
            .invoke(manager, *args)
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> managerField(manager: BleManager, name: String): T {
        val field = BleManager::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.get(manager) as T
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> privateField(target: Any, name: String): T {
        val field = target::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.get(target) as T
    }
}
