package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.util.Log
import java.lang.ref.WeakReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.mockito.Mockito

/** 蓝牙 OFF 必须走真实 Manager 入口清掉已失效 GATT session 的 OTA 写状态。 */
class BleManagerBluetoothOffOtaTeardownTest {

    @Test
    fun `bluetooth off cancels accepted ota write before clearing upgrade marker`() {
        val manager = BleManager.instance
        setWeakContext(manager, null)
        manager.cleanConnectCache()
        val endpoint = "AA:BB:CC:DD:EE:FF"
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = BleAndroidOtaWriteQueue(
            endpoint = endpoint,
            submit = { BleOtaWriteSubmission.accepted() },
            scheduler = BleOtaWriteScheduler { _, _ -> BleOtaWriteCancellable {} },
            nowMillis = { 0L },
        )
        queue.enqueue(byteArrayOf(0x01)) { completions.add(it) }

        otaWriteQueues(manager)[endpoint.lowercase()] = queue
        upgradeDevices(manager).add(endpoint)

        val handleBluetoothStateChanged = BleManager::class.java.getDeclaredMethod(
            "handleBluetoothStateChanged",
            Int::class.javaPrimitiveType,
        ).also { it.isAccessible = true }

        Mockito.mockStatic(Log::class.java).use {
            try {
                // Hostile timeline: RAW 已被 Android 接受但 callback 未返回，此时关闭蓝牙。
                handleBluetoothStateChanged.invoke(manager, BluetoothAdapter.STATE_OFF)

                assertEquals("ota_write_cancelled", completions.single()?.code)
                assertTrue(otaWriteQueues(manager).isEmpty())
                assertTrue(upgradeDevices(manager).isEmpty())
                assertEquals(0, queue.queueDepth)
                assertTrue(!queue.hasOutstandingGattWrite)
            } finally {
                // 单例 Manager 供同一 JVM 的其它测试复用，恢复 Gate/蓝牙状态避免跨测试污染。
                handleBluetoothStateChanged.invoke(manager, BluetoothAdapter.STATE_ON)
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
}
