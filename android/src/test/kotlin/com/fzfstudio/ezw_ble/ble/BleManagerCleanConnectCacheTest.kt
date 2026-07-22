package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.lang.ref.WeakReference
import org.mockito.Mockito

/** cleanConnectCache 的真实 manager runtime 行为测试，不依赖源码字符串匹配。 */
class BleManagerCleanConnectCacheTest {
    @Test
    fun `clean closes device gatt and invalidates every admission phase`() {
        val manager = BleManager.instance
        manager.cleanConnectCache()
        val devices = managerField<MutableList<BleDevice>>(manager, "connectedDevices")
        devices.clear()

        val gatt = Mockito.mock(BluetoothGatt::class.java)
        val device = BleDevice(
            belongConfig = BleConfig.empty().copy(name = "g2", autoReconnect = true),
            name = "G2_A",
            uuid = "connected",
            sn = "sn",
            rssi = 0,
            connectState = BleConnectState.CONNECTED,
        )
        device.update(gatt)
        devices += device

        val active = registerAttempt(manager, "active")
        val waiting = registerAttempt(manager, "waiting")
        val prephysical = registerAttempt(manager, "prephysical")
        val gate = managerField<BleConnectionAdmissionGate>(manager, "connectionAdmissionGate")
        assertEquals(BleConnectionAdmissionDecision.GRANTED, gate.onPhysicalConnected(active))
        assertEquals(BleConnectionAdmissionDecision.QUEUED, gate.onPhysicalConnected(waiting))

        manager.cleanConnectCache()

        Mockito.verify(gatt).disconnect()
        Mockito.verify(gatt).close()
        assertNull(device.myGatt)
        assertTrue(managerField<MutableMap<*, *>>(manager, "currentAdmissions").isEmpty())
        assertTrue(managerField<MutableMap<*, *>>(manager, "admittedGattSessions").isEmpty())
        assertTrue(managerField<MutableMap<*, *>>(manager, "businessConnectedGattSessions").isEmpty())
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(active))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(waiting))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(prephysical))

        val generations = managerField<MutableMap<String, Long>>(manager, "connectionAttemptGenerations")
        assertTrue((generations["active"] ?: 0L) > active.generation)
        devices.clear()
    }

    @Test
    fun `init config removal closes and invalidates active waiting and prephysical sessions`() {
        val manager = BleManager.instance
        manager.cleanConnectCache()
        val devices = managerField<MutableList<BleDevice>>(manager, "connectedDevices")
        devices.clear()
        val revokedConfig = BleConfig.empty().copy(name = "revoked", autoReconnect = true)
        manager.initConfigs(listOf(revokedConfig))

        val gatts = mutableListOf<BluetoothGatt>()
        listOf("active", "waiting", "prephysical").forEach { uuid ->
            val gatt = Mockito.mock(BluetoothGatt::class.java)
            gatts += gatt
            devices += BleDevice(
                belongConfig = revokedConfig,
                name = "G2_$uuid",
                uuid = uuid,
                sn = "sn-$uuid",
                rssi = 0,
                connectState = BleConnectState.NONE,
            ).also { it.update(gatt) }
        }
        val active = registerAttempt(manager, "active")
        val waiting = registerAttempt(manager, "waiting")
        val prephysical = registerAttempt(manager, "prephysical")
        val gate = managerField<BleConnectionAdmissionGate>(manager, "connectionAdmissionGate")
        gate.onPhysicalConnected(active)
        gate.onPhysicalConnected(waiting)

        // JVM local test 没有 android.util.Log 实现；静态 mock 只隔离日志，不替换被测状态机。
        Mockito.mockStatic(Log::class.java).use {
            manager.initConfigs(emptyList())
        }

        gatts.forEach { gatt ->
            Mockito.verify(gatt).disconnect()
            Mockito.verify(gatt).close()
        }
        assertTrue(managerField<MutableMap<*, *>>(manager, "currentAdmissions").isEmpty())
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(active))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(waiting))
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(prephysical))
        assertTrue(devices.all { it.myGatt == null && it.connectState == BleConnectState.NONE })
        devices.clear()
    }

    @Test
    fun `reset preserves persisted reconnect owner and invalidates runtime callback`() {
        val manager = BleManager.instance
        manager.cleanConnectCache()
        managerField<MutableList<BleDevice>>(manager, "connectedDevices").clear()
        val preferences = InMemorySharedPreferences()
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(
            context.getSharedPreferences(Mockito.anyString(), Mockito.anyInt()),
        ).thenReturn(preferences)
        val weakContextField = BleManager::class.java.getDeclaredField("weakContext")
        weakContextField.isAccessible = true
        weakContextField.set(manager, WeakReference(context))

        val owner = BleDevice(
            belongConfig = BleConfig.empty().copy(name = "reset-owner", autoReconnect = true),
            name = "G2_Reset",
            uuid = "AA:BB:CC:DD:EE:FF",
            sn = "reset-sn",
            rssi = 0,
            connectState = BleConnectState.NONE,
        )
        val store = BleReconnectStore()
        store.upsertTarget(context, owner)
        val stale = registerAttempt(manager, owner.uuid)
        val gate = managerField<BleConnectionAdmissionGate>(manager, "connectionAdmissionGate")

        Mockito.mockStatic(Log::class.java).use {
            manager.reset()
        }

        assertEquals(listOf(owner.uuid), store.targets(context).map { it.uuid })
        assertEquals(BleConnectionAdmissionDecision.STALE, gate.onPhysicalConnected(stale))
        store.clearTargets(context)
    }

    @Test
    fun `repeated batch cancellation keeps manager and gate generations converged`() {
        val manager = BleManager.instance
        manager.cleanConnectCache()
        managerField<MutableList<BleDevice>>(manager, "connectedDevices").clear()
        val endpoint = "AA:BB:CC:DD:EE:10"
        val gate = managerField<BleConnectionAdmissionGate>(manager, "connectionAdmissionGate")

        // 1、直接验证批量取消共用的原子失效器，避开本地 JVM 未实现的 Android
        // org.json 持久化 stub；完整 cancel 调用顺序由 Dart native contract test 锁定。
        repeat(3) {
            invalidateAttempts(manager, setOf(endpoint))
        }

        // 2、下一次真实连接必须能注册到 Gate 当前高水位，而不是在物理回调时被判 STALE。
        val fresh = registerAttempt(manager, endpoint)
        assertEquals(fresh.generation, gate.latestGeneration(endpoint))
        assertEquals(BleConnectionAdmissionDecision.GRANTED, gate.onPhysicalConnected(fresh))
    }

    private fun invalidateAttempts(
        manager: BleManager,
        endpoints: Set<String>,
    ): BleConnectionAdmission? {
        val method = BleManager::class.java.getDeclaredMethod(
            "invalidateConnectionAttempts",
            Set::class.java,
        )
        method.isAccessible = true
        return method.invoke(manager, endpoints) as BleConnectionAdmission?
    }

    private fun registerAttempt(manager: BleManager, endpoint: String): BleConnectionAdmission {
        val method = BleManager::class.java.getDeclaredMethod(
            "registerConnectionAttempt",
            String::class.java,
            BleConnectSource::class.java,
            Long::class.javaPrimitiveType,
        )
        method.isAccessible = true
        return method.invoke(manager, endpoint, BleConnectSource.AUTO_RECONNECT, 0L) as BleConnectionAdmission
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> managerField(manager: BleManager, name: String): T {
        val field = BleManager::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.get(manager) as T
    }
}

/** JVM 行为测试使用的最小 SharedPreferences；写入即时生效，符合 apply 的可见性契约。 */
private class InMemorySharedPreferences : SharedPreferences {
    private val values = linkedMapOf<String, Any?>()

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<String>)?.toMutableSet() ?: defValues
    override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue
    override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue
    override fun getFloat(key: String?, defValue: Float): Float = values[key] as? Float ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
    override fun contains(key: String?): Boolean = values.containsKey(key)
    override fun edit(): SharedPreferences.Editor = Editor(values)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    private class Editor(
        private val values: MutableMap<String, Any?>,
    ) : SharedPreferences.Editor {
        override fun putString(key: String?, value: String?): SharedPreferences.Editor = apply { key?.let { values[it] = value } }
        override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor =
            apply { key?.let { this.values[it] = values?.toSet() } }
        override fun putInt(key: String?, value: Int): SharedPreferences.Editor = apply { key?.let { values[it] = value } }
        override fun putLong(key: String?, value: Long): SharedPreferences.Editor = apply { key?.let { values[it] = value } }
        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = apply { key?.let { values[it] = value } }
        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = apply { key?.let { values[it] = value } }
        override fun remove(key: String?): SharedPreferences.Editor = apply { key?.let(values::remove) }
        override fun clear(): SharedPreferences.Editor = apply { values.clear() }
        override fun commit(): Boolean = true
        override fun apply() = Unit
    }
}
