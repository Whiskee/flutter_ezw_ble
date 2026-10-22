package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.util.Log
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.BleScan
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import java.lang.ref.WeakReference
import java.util.Timer
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Delay
import kotlinx.coroutines.DisposableHandle
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue
import org.mockito.Mockito

/** Real Manager scan starts prove that owner mode changes do not restart the shared Android scan. */
class BleManagerSharedScanTest {
    @Test
    fun `normal pure normal updates one physical scan and preserves ordinary device cache`() {
        Fixture().use { f ->
            val first = f.manager.startScan()
            val generation = first["generation"]
            val cached = BleDevice(f.config, "R1", "AA:00:00:00:00:01", "stable-ring", -60, BleConnectState.NONE)
            f.cache += cached

            val pure = f.manager.startScan(pureModel = true, includeNormalScanResults = true)
            assertEquals(generation, pure["generation"])
            assertEquals("alreadyRunning", pure["reason"])
            assertTrue(f.field("scanPureMode"))
            assertTrue(f.field("scanIncludeNormalResults"))
            assertSame(cached, f.cache.single())

            val normal = f.manager.startScan()
            assertEquals(generation, normal["generation"])
            assertFalse(f.field("scanPureMode"))
            assertFalse(f.field("scanIncludeNormalResults"))
            assertSame(cached, f.cache.single())
            assertEquals(1, f.callbacks.size, "mode updates must reuse the original radio callback")
            Mockito.verify(f.scanner, Mockito.never()).stopScan(Mockito.any(ScanCallback::class.java))
        }
    }

    @Test
    fun `stopped and replaced scan callbacks cannot write new generation cache`() {
        Fixture().use { f ->
            val first = f.manager.startScan()
            val oldCallback = f.callbacks.single()
            val oldResult = f.advertisement("AA:00:00:00:00:01")
            f.manager.stopScan()
            oldCallback.onScanResult(1, oldResult)
            assertTrue(f.cache.isEmpty(), "stopped scan callback must have no native side effects")

            val second = f.manager.startScan()
            assertTrue((second["generation"] as Long) > (first["generation"] as Long))
            oldCallback.onScanResult(1, oldResult)
            oldCallback.onScanFailed(2)
            assertTrue(f.field("isScanning"), "old failure cannot retire the replacement scan")
            assertEquals(second["generation"], f.field<Long>("activeScanGeneration"))
            assertTrue(f.cache.isEmpty(), "old scan callback must not populate the replacement cache")
            f.callbacks.last().onScanResult(1, f.advertisement("AA:00:00:00:00:02"))
            assertEquals(listOf("AA:00:00:00:00:02"), f.cache.map { it.uuid })
        }
    }

    @Test
    fun `connect refresh reuses shared pure policy and expiry preserves external scanner`() {
        Fixture().use { f ->
            val start = f.manager.startScan(pureModel = true, includeNormalScanResults = true)
            f.connect("AA:00:00:00:00:11", remoteName = null, requestName = "")
            assertEquals(1, f.field<Map<*, *>>("scanRefreshGenerations").size)
            assertTrue(f.field("scanPureMode"), "native ensure-running must preserve Dart pure policy")
            assertTrue(f.field("scanIncludeNormalResults"))
            f.clock.advanceBy(10_000)
            assertTrue(f.field<Map<*, *>>("scanRefreshGenerations").isEmpty())
            assertTrue(f.field("isScanning"), "finishing refresh must retain the external scanner")
            assertEquals(start["generation"], f.field<Long>("activeScanGeneration"))
            Mockito.verify(f.scanner, Mockito.never()).stopScan(Mockito.any(ScanCallback::class.java))
        }
    }

    @Test
    fun `real pending match opens gatt while peer shared scanner remains active`() {
        Fixture().use { f ->
            val start = f.manager.startScan(pureModel = true, includeNormalScanResults = false)
            val target = "AA:00:00:00:00:21"
            f.connect(target)
            assertEquals(1, f.field<List<*>>("pendingScanConnects").size)
            f.callbacks.single().onScanResult(1, f.advertisement(target))
            assertTrue(f.field<List<*>>("pendingScanConnects").isEmpty())
            assertEquals(listOf(target), f.opened, "real connect reentry must open GATT")
            assertTrue(f.field("isScanning"), "last native pending does not own the Dart scan")
            assertEquals(start["generation"], f.field<Long>("activeScanGeneration"))
            f.callbacks.single().onScanResult(1, f.advertisement("AA:00:00:00:00:22"))
            assertEquals(2, f.cache.size, "unrelated peer must still be discoverable")
            Mockito.verify(f.scanner, Mockito.never()).stopScan(Mockito.any(ScanCallback::class.java))
        }
    }

    @Test
    fun `real pending timeout retains external scan while native only timeout releases it`() {
        for (external in listOf(true, false)) Fixture(connectTimeout = 1.0).use { f ->
            if (external) f.manager.startScan(pureModel = true)
            f.connect("AA:00:00:00:00:31")
            assertEquals(1, f.field<List<*>>("pendingScanConnects").size)
            // The production pending deadline uses wall time; only this 1ms budget is real.
            Thread.sleep(10)
            f.clock.advanceBy(1)
            assertTrue(f.field<List<*>>("pendingScanConnects").isEmpty())
            assertEquals(external, f.field<Boolean>("isScanning"))
            Mockito.verify(f.scanner, Mockito.times(if (external) 0 else 1))
                .stopScan(Mockito.any(ScanCallback::class.java))
        }
    }

    @Test
    fun `external release restores ordinary mode until pending match releases native scanner`() {
        Fixture().use { f ->
            val start = f.manager.startScan(pureModel = true, includeNormalScanResults = true)
            val target = "AA:00:00:00:00:41"
            f.connect(target)
            f.manager.releaseExternalScanLease()
            assertFalse(f.field("hasExternalScanLease"))
            assertTrue(f.field("isScanning"))
            assertFalse(f.field("scanPureMode"))
            assertFalse(f.field("scanIncludeNormalResults"))
            assertEquals(start["generation"], f.field<Long>("activeScanGeneration"))
            assertEquals(1, f.callbacks.size)
            f.callbacks.single().onScanResult(1, f.advertisement(target))
            assertEquals(listOf(target), f.opened)
            assertFalse(f.field("isScanning"))
            Mockito.verify(f.scanner, Mockito.times(1)).stopScan(Mockito.any(ScanCallback::class.java))
        }
    }

    @Test
    fun `external release keeps refresh until native completion and preserves cache identity`() {
        Fixture().use { f ->
            val start = f.manager.startScan(pureModel = true)
            f.connect("AA:00:00:00:00:51", remoteName = null, requestName = "")
            f.callbacks.single().onScanResult(1, f.advertisement("AA:00:00:00:00:52"))
            val cached = f.cache.single()
            f.manager.releaseExternalScanLease()
            assertTrue(f.field("isScanning"))
            assertFalse(f.field("scanPureMode"))
            assertSame(cached, f.cache.single())
            assertEquals(start["generation"], f.field<Long>("activeScanGeneration"))
            f.clock.advanceBy(10_000)
            assertFalse(f.field("isScanning"))
            assertTrue(f.field<Map<*, *>>("scanRefreshGenerations").isEmpty())
            Mockito.verify(f.scanner, Mockito.times(1)).stopScan(Mockito.any(ScanCallback::class.java))
        }
    }

    @Test
    fun `production disconnect cancels only native pending or refresh demand`() {
        for (refresh in listOf(true, false)) for (external in listOf(true, false)) Fixture().use { f ->
            if (external) f.manager.startScan(pureModel = true)
            val target = "AA:00:00:00:00:61"
            f.connect(target, remoteName = if (refresh) null else "R1", requestName = if (refresh) "" else "R1")
            f.manager.disconnect(target)
            assertTrue(f.field<List<*>>("pendingScanConnects").isEmpty())
            assertTrue(f.field<Map<*, *>>("scanRefreshGenerations").isEmpty())
            assertEquals(external, f.field<Boolean>("isScanning"))
            assertEquals(external, f.field<Boolean>("scanPureMode"))
            f.clock.advanceBy(20_000)
            assertTrue(f.opened.isEmpty(), "cancelled native delay must not open a late GATT")
            assertEquals(external, f.field<Boolean>("isScanning"))
        }
    }

    @Test
    fun `native only pending match stops its scanner without acquiring external lease`() {
        Fixture().use { f ->
            val target = "AA:00:00:00:00:71"
            f.connect(target)
            assertFalse(f.field("hasExternalScanLease"))
            assertTrue(f.field("isScanning"))
            f.callbacks.single().onScanResult(1, f.advertisement(target))
            assertEquals(listOf(target), f.opened)
            assertFalse(f.field("isScanning"))
            Mockito.verify(f.scanner, Mockito.times(1)).stopScan(Mockito.any(ScanCallback::class.java))
        }
    }

    @Test
    fun `failed physical starts and current failures cannot leave a lease or erase replacement lease`() {
        Fixture().use { f ->
            Mockito.`when`(f.adapter.bluetoothLeScanner).thenReturn(null)
            assertEquals(false, f.manager.startScan(pureModel = true)["started"])
            assertFalse(f.field("hasExternalScanLease"))
            Mockito.`when`(f.adapter.bluetoothLeScanner).thenReturn(f.scanner)
            f.manager.startScan(pureModel = true)
            val old = f.callbacks.single()
            old.onScanFailed(2)
            assertFalse(f.field("hasExternalScanLease"))
            assertFalse(f.field("isScanning"))
            val replacement = f.manager.startScan(pureModel = true)
            old.onScanFailed(2)
            assertTrue(f.field("hasExternalScanLease"))
            assertEquals(replacement["generation"], f.field<Long>("activeScanGeneration"))
            f.manager.reset()
            assertFalse(f.field("hasExternalScanLease"))
            assertFalse(f.field("isScanning"))
        }
    }

    @Test
    fun `bluetooth off invalidates external lease and callbacks before replacement scan`() {
        Fixture().use { f ->
            f.manager.startScan(pureModel = true)
            val old = f.callbacks.single()
            f.bluetoothState(BluetoothAdapter.STATE_OFF)
            assertFalse(f.field("hasExternalScanLease"))
            assertFalse(f.field("isScanning"))
            old.onScanResult(1, f.advertisement("AA:00:00:00:00:81"))
            assertTrue(f.cache.isEmpty())
            f.bluetoothState(BluetoothAdapter.STATE_ON)
            val replacement = f.manager.startScan(pureModel = true)
            old.onScanFailed(2)
            assertTrue(f.field("hasExternalScanLease"))
            assertEquals(replacement["generation"], f.field<Long>("activeScanGeneration"))
        }
    }

    @Test
    fun `new external owner sees cached peer only on next fresh callback during native keepalive`() {
        Fixture().use { f ->
            val peer = "AA:00:00:00:00:91"
            val start = f.manager.startScan()
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            assertEquals(listOf(false), f.scanEventKinds)
            val cached = f.cache.single()
            f.connect("AA:00:00:00:00:92", remoteName = "R1Other", requestName = "R1Other")
            assertEquals(1, f.field<List<*>>("pendingScanConnects").size)
            f.manager.releaseExternalScanLease()
            f.callbacks.single().onScanResult(1, f.advertisement("AA:00:00:00:00:93", "R1Native"))
            assertEquals(listOf(false, false), f.scanEventKinds, "native-only delivery can predate the next owner")
            val replacement = f.manager.startScan()
            assertEquals(start["generation"], replacement["generation"])
            assertEquals(2, f.scanEventKinds.size, "owner acquisition cannot replay historical advertisements")
            assertSame(cached, f.cache.first())
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            assertEquals(listOf(false, false, false), f.scanEventKinds)
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            assertEquals(3, f.scanEventKinds.size, "the new ordinary demand still deduplicates repeats")
            assertEquals(1, f.callbacks.size)
        }
    }

    @Test
    fun `ordinary eligibility reentry during continuous pure lease redelivers only fresh results`() {
        Fixture().use { f ->
            val peer = "AA:00:00:00:00:A1"
            val start = f.manager.startScan()
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            f.manager.startScan(pureModel = true, includeNormalScanResults = true)
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            assertEquals(listOf(false, true), f.scanEventKinds, "continuous ordinary demand must remain deduplicated")
            f.manager.startScan(pureModel = true, includeNormalScanResults = false)
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            val beforeJoin = f.scanEventKinds.size
            val joined = f.manager.startScan(pureModel = true, includeNormalScanResults = true)
            assertEquals(start["generation"], joined["generation"])
            assertEquals(beforeJoin, f.scanEventKinds.size, "mode update cannot replay cached data")
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            assertEquals(listOf(false, true, true, true, false), f.scanEventKinds)
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            assertEquals(2, f.scanEventKinds.count { !it })
            f.manager.startScan()
            f.callbacks.single().onScanResult(1, f.advertisement(peer))
            assertEquals(2, f.scanEventKinds.count { !it }, "continuous mixed to normal demand remains deduplicated")
            assertEquals(1, f.callbacks.size)
        }
    }

    /** Radio and context are mocked; all manager lifecycle and generation logic remains production code. */
    private class Fixture(connectTimeout: Double = 15_000.0) : AutoCloseable {
        private val logs = Mockito.mockStatic(Log::class.java)
        val scanEventKinds = mutableListOf<Boolean>()
        private val json = Mockito.mockConstruction(JSONObject::class.java,
            Mockito.withSettings().defaultAnswer { call ->
                if (call.method.name == "put" && call.arguments[0] == "isPureScanResult") {
                    scanEventKinds += call.arguments[1] as Boolean
                }
                if (call.method.name == "toString") "{}" else Mockito.RETURNS_SELF.answer(call)
            })
        // Capturing construction keeps GATT timeout timers deterministic and thread-local.
        private val timers = Mockito.mockConstruction(Timer::class.java)
        val clock = ScanClock()
        private val asyncErrors = mutableListOf<Throwable>()
        private val scope = CoroutineScope(clock + SupervisorJob() + CoroutineExceptionHandler { _, error ->
            asyncErrors += error
        })
        private val settings = Mockito.mock(ScanSettings::class.java)
        private val builders = Mockito.mockConstruction(
            ScanSettings.Builder::class.java,
            Mockito.withSettings().defaultAnswer(Mockito.RETURNS_SELF),
        ) { builder, _ -> Mockito.`when`(builder.build()).thenReturn(settings) }
        val manager = BleManager::class.java.getDeclaredConstructor()
            .also { it.isAccessible = true }.newInstance()
        val adapter = Mockito.mock(BluetoothAdapter::class.java)
        val opened = mutableListOf<String>()
        val scanner = Mockito.mock(BluetoothLeScanner::class.java)
        val callbacks = mutableListOf<ScanCallback>()
        val config = BleConfig.empty().copy(
            name = "ring", connectTimeout = connectTimeout, scan = BleScan(listOf("R1"), null, 1),
            privateServices = listOf(BlePrivateService("00002760-08c2-11e1-9073-0e8ac72e5450")),
        )
        val cache: MutableList<BleDevice> get() = field("scanResultTemp")

        init {
            val context = Mockito.mock(Context::class.java)
            val systemManager = Mockito.mock(BluetoothManager::class.java)
            Mockito.`when`(systemManager.adapter).thenReturn(adapter)
            Mockito.`when`(adapter.isEnabled).thenReturn(true)
            Mockito.`when`(adapter.bluetoothLeScanner).thenReturn(scanner)
            Mockito.doAnswer { invocation ->
                callbacks.add(invocation.getArgument(2))
                null
            }.`when`(scanner).startScan(Mockito.isNull(), Mockito.any(ScanSettings::class.java), Mockito.any(ScanCallback::class.java))
            set("mainScope", scope)
            set("weakContext", WeakReference(context))
            set("bluetoothManager", systemManager)
            set("bleConfigs", listOf(config))
            set("bleState", 5)
            set("blePermission", true)
            set("bleLocation", true)
        }

        /** Enter through the production connection planner; no pending/cache state is injected. */
        fun connect(address: String, remoteName: String? = "R1", requestName: String = "R1") {
            val remote = Mockito.mock(BluetoothDevice::class.java)
            val gatt = Mockito.mock(BluetoothGatt::class.java)
            Mockito.`when`(adapter.getRemoteDevice(address)).thenReturn(remote)
            Mockito.`when`(remote.address).thenReturn(address)
            Mockito.`when`(remote.name).thenReturn(remoteName)
            Mockito.`when`(gatt.device).thenReturn(remote)
            Mockito.`when`(remote.connectGatt(Mockito.nullable(Context::class.java), Mockito.anyBoolean(),
                Mockito.any(BluetoothGattCallback::class.java))).thenAnswer {
                opened += address
                gatt
            }
            manager.connect(config.name, address, requestName, "", sessionGeneration = 101L)
        }

        fun advertisement(address: String, name: String = "R1"): ScanResult {
            val device = Mockito.mock(BluetoothDevice::class.java)
            val record = Mockito.mock(ScanRecord::class.java)
            val result = Mockito.mock(ScanResult::class.java)
            Mockito.`when`(device.address).thenReturn(address)
            Mockito.`when`(record.deviceName).thenReturn(name)
            Mockito.`when`(result.device).thenReturn(device)
            Mockito.`when`(result.scanRecord).thenReturn(record)
            return result
        }

        /** Deliver the same physical power callback used by the registered Bluetooth listener. */
        fun bluetoothState(state: Int) = BleManager::class.java
            .getDeclaredMethod("handleBluetoothStateChanged", Int::class.javaPrimitiveType)
            .also { it.isAccessible = true }.invoke(manager, state)

        @Suppress("UNCHECKED_CAST")
        fun <T> field(name: String): T = BleManager::class.java.getDeclaredField(name)
            .also { it.isAccessible = true }.get(manager) as T

        private fun set(name: String, value: Any) = BleManager::class.java.getDeclaredField(name)
            .also { it.isAccessible = true }.set(manager, value)

        override fun close() {
            try {
                manager.release()
                scope.cancel()
                assertTrue(asyncErrors.isEmpty(), asyncErrors.toString())
            } finally {
                builders.close()
                timers.close()
                json.close()
                logs.close()
            }
        }
    }
    /** Virtual coroutine delays exercise real refresh/pending jobs without 10-second sleeps. */
    @OptIn(InternalCoroutinesApi::class)
    private class ScanClock : CoroutineDispatcher(), Delay {
        private data class Deadline(val at: Long, val run: () -> Unit, var cancelled: Boolean = false)
        private var now = 0L
        private val deadlines = mutableListOf<Deadline>()
        override fun dispatch(context: CoroutineContext, block: Runnable) = block.run()
        override fun scheduleResumeAfterDelay(timeMillis: Long, continuation: CancellableContinuation<Unit>) {
            val deadline = Deadline(now + timeMillis, { if (continuation.isActive) continuation.resume(Unit) })
            deadlines += deadline
            continuation.invokeOnCancellation { deadline.cancelled = true }
        }
        override fun invokeOnTimeout(timeMillis: Long, block: Runnable, context: CoroutineContext): DisposableHandle {
            val deadline = Deadline(now + timeMillis, { block.run() })
            deadlines += deadline
            return DisposableHandle { deadline.cancelled = true }
        }
        fun advanceBy(millis: Long) {
            val target = now + millis
            while (true) {
                val next = deadlines.filter { !it.cancelled && it.at <= target }.minByOrNull { it.at } ?: break
                deadlines.remove(next)
                now = next.at
                next.run()
            }
            now = target
        }
    }
}
