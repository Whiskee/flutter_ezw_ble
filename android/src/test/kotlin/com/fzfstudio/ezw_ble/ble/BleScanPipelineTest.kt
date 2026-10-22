package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BleScan
import com.fzfstudio.ezw_ble.ble.models.BleSnRule
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import org.mockito.Mockito

/** Exercises Android's real ScanCallback entry point so callback name collisions cannot hide in source checks. */
class BleScanPipelineTest {

    @Test
    fun `scan failure forwards its code once and logs once`() {
        val reportedCodes = mutableListOf<Int>()
        val logs = mutableListOf<Pair<BleLoggerTag, String>>()
        val pipeline = BleScanPipeline(
            bleConfigs = { emptyList() },
            scanPureMode = { false },
            scanResultTemp = mutableListOf<BleDevice>(),
            expirePendingScanConnects = {},
            tryConnectFromPendingScan = {},
            emitMatchDevices = { _, _, _ -> },
            reportScanFailure = { reportedCodes.add(it) },
            sendLog = { tag, message -> logs.add(tag to message) },
        )

        // A platform failure must return after one manager handoff; recursive dispatch previously overflowed here.
        pipeline.onScanFailed(2)

        assertEquals(listOf(2), reportedCodes)
        assertEquals(listOf(BleLoggerTag.e to "Start scan: error = 2"), logs)
    }

    @Test
    fun `late pure observer receives fresh cached-address advertisements without replacing ordinary cache`() {
        val f = Fixture()
        val result = f.advertisement("R1", "AA:00:00:00:00:01", "SER_RING")
        f.pipeline.onScanResult(1, result)
        val stable = f.cache.single()
        assertEquals("SER_RING", stable.sn)
        assertEquals(1, f.events.size)

        // The DFU owner joins while the ordinary peer continues holding the same scan.
        f.pure = true
        f.includeNormal = true
        assertEquals(1, f.events.size, "mode changes must not replay a historical advertisement")
        f.pipeline.onScanResult(1, result)
        f.pipeline.onScanResult(1, result)
        assertEquals(3, f.events.size, "each new physical callback must reach the late pure observer")
        assertEquals(listOf(false, true, true), f.pureFlags)
        assertEquals(listOf(stable), f.cache, "random raw identities cannot replace ordinary cache")
        assertNotEquals("SER_RING", f.events.last().first)
        assertEquals(listOf(stable), f.pending, "raw observations must not drive native connection routing")

        f.pure = false
        f.pipeline.onScanResult(1, result)
        assertEquals(3, f.events.size, "ordinary duplicate suppression survives pure owner release")
        assertEquals(listOf(stable), f.cache)
    }

    @Test
    fun `pure only output still maintains stable G2 peers and native pending routes`() {
        val f = Fixture()
        f.pure = true
        f.pipeline.onScanResult(1, f.advertisement("G2_L", "AA:00:00:00:00:02", "SER_PAIR"))
        f.pipeline.onScanResult(1, f.advertisement("G2_R", "AA:00:00:00:00:03", "SER_PAIR"))
        assertEquals(listOf("SER_PAIR", "SER_PAIR"), f.cache.map { it.sn })
        assertEquals(f.cache, f.pending, "both fresh peers still advance stable scan-first routing")
        assertEquals(2, f.events.size, "pure-only owner must not add ordinary Dart events")
        assertEquals(listOf(true, true), f.pureFlags)
        assertEquals(listOf(1, 1), f.events.map { it.second.size })

        // Removing the pure owner must leave both stable legs available for ordinary connect lookups.
        f.pure = false
        assertEquals(2, f.cache.size)
        assertEquals(setOf("AA:00:00:00:00:02", "AA:00:00:00:00:03"), f.cache.map { it.uuid }.toSet())
    }

    @Test
    fun `shared pure observer does not interrupt ordinary two-leg aggregation`() {
        val f = Fixture()
        f.pipeline.onScanResult(1, f.advertisement("G2_L", "AA:00:00:00:00:02", "SER_PAIR"))
        assertEquals(0, f.events.size)
        f.pure = true
        f.includeNormal = true
        val right = f.advertisement("G2_R", "AA:00:00:00:00:03", "SER_PAIR")
        f.pipeline.onScanResult(1, right)
        assertEquals(listOf(true, false), f.pureFlags)
        assertEquals(listOf(1, 2), f.events.map { it.second.size })
        assertEquals("SER_PAIR", f.events.last().first)
        assertEquals(listOf("SER_PAIR", "SER_PAIR"), f.events.last().second.map { it.sn })
        assertEquals(f.cache, f.pending)

        f.pipeline.onScanResult(1, right)
        assertEquals(listOf(true, false, true), f.pureFlags, "repeat advertisements refresh only raw observers")
        assertEquals(2, f.cache.size)
        assertEquals(2, f.pending.size)
    }

    @Test
    fun `ordinary owner joining pure-only scan receives stable peers on next live callback`() {
        val f = Fixture()
        f.pure = true
        val right = f.advertisement("G2_R", "AA:00:00:00:00:03", "SER_PAIR")
        f.pipeline.onScanResult(1, f.advertisement("G2_L", "AA:00:00:00:00:02", "SER_PAIR"))
        f.pipeline.onScanResult(1, right)
        assertEquals(listOf(true, true), f.pureFlags)
        f.includeNormal = true
        assertEquals(2, f.events.size, "adding an owner must not replay historical cache")
        f.pipeline.onScanResult(1, right)
        assertEquals(listOf(true, true, true, false), f.pureFlags)
        assertEquals(2, f.events.last().second.size)
        assertEquals("SER_PAIR", f.events.last().first)
        f.pipeline.onScanResult(1, right)
        assertEquals(listOf(true, true, true, false, true), f.pureFlags)
        assertEquals(2, f.pending.size)
    }

    @Test
    fun `scan response completes R1 stable identity during pure observation`() {
        val f = Fixture()
        f.pipeline.onScanResult(1, f.advertisement("R1_FALLBACK", "AA:00:00:00:00:04", ""))
        assertEquals("R1_FALLBACK", f.cache.single().sn)
        f.pure = true
        f.includeNormal = true
        f.pipeline.onScanResult(1, f.advertisement("R1_FALLBACK", "AA:00:00:00:00:04", "SER_REAL_RING"))
        assertEquals("SER_REAL_RING", f.cache.single().sn)
        assertEquals(listOf(false, true, false), f.pureFlags)
        assertEquals(listOf("R1_FALLBACK", "SER_REAL_RING"), f.pending.map { it.sn })
        assertEquals("SER_REAL_RING", f.events.last().first)
    }

    @Test
    fun `ordinary cache eviction permits fresh rediscovery of the same address`() {
        val f = Fixture()
        val result = f.advertisement("R1", "AA:00:00:00:00:01", "SER_RING")
        f.pipeline.onScanResult(1, result)
        // initConfigs revocation can evict this config's cache without stopping peer scans.
        f.cache.removeAll { it.belongConfig.name == "ring" }
        f.pipeline.onScanResult(1, result)
        assertEquals(listOf(false, false), f.pureFlags)
        assertEquals(1, f.cache.size)
    }

    @Test
    fun `release during pure event cannot continue native cache or pending routing`() {
        val f = Fixture()
        f.pure = true
        f.onEmit = { f.active = false }
        f.pipeline.onScanResult(1, f.advertisement("R1", "AA:00:00:00:00:01", "SER_RING"))
        assertEquals(listOf(true), f.pureFlags)
        assertEquals(0, f.cache.size)
        assertEquals(0, f.pending.size)
    }

    /** Real Android callbacks with mocked radio input retain production SN parsing and cache routing. */
    private class Fixture {
        var pure = false
        var includeNormal = false
        var active = true
        var onEmit: () -> Unit = {}
        val cache = mutableListOf<BleDevice>()
        val pending = mutableListOf<BleDevice>()
        val events = mutableListOf<Pair<String, List<BleDevice>>>()
        val pureFlags = mutableListOf<Boolean>()
        private val configs = listOf(
            BleConfig.empty().copy(name = "fallback-ring", scan = scan(listOf("R1_FALLBACK"), 1, listOf("R1", "SER_"))),
            BleConfig.empty().copy(name = "ring", scan = scan(listOf("R1"), 1)),
            BleConfig.empty().copy(name = "glasses", scan = scan(listOf("G2_"), 2)),
        )
        val pipeline = BleScanPipeline(
            bleConfigs = { configs },
            scanPureMode = { pure },
            scanIncludeNormalResults = { includeNormal },
            isActiveScan = { active },
            scanResultTemp = cache,
            expirePendingScanConnects = {},
            tryConnectFromPendingScan = { pending.add(it) },
            emitMatchDevices = { sn, devices, isPure ->
                events.add(sn to devices)
                pureFlags.add(isPure)
                onEmit()
            },
            reportScanFailure = {},
            sendLog = { _, _ -> },
        )

        fun advertisement(name: String, address: String, sn: String): ScanResult {
            val device = Mockito.mock(BluetoothDevice::class.java)
            val record = Mockito.mock(ScanRecord::class.java)
            val result = Mockito.mock(ScanResult::class.java)
            Mockito.`when`(device.address).thenReturn(address)
            Mockito.`when`(record.deviceName).thenReturn(name)
            Mockito.`when`(record.bytes).thenReturn(sn.toByteArray())
            Mockito.`when`(result.device).thenReturn(device)
            Mockito.`when`(result.scanRecord).thenReturn(record)
            Mockito.`when`(result.rssi).thenReturn(-60)
            return result
        }

        private fun scan(names: List<String>, count: Int, filters: List<String> = listOf("SER_")) = BleScan(
            nameFilters = names,
            snRule = BleSnRule(0, 0, "", filters),
            matchCount = count,
        )
    }

}
