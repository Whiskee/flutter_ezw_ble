package com.fzfstudio.ezw_ble.ble

import kotlin.test.*

class BleStreamLogSummaryTest {
    @Test
    fun `concurrent packet producers preserve all counts in one session window`() {
        var now = 0L
        val summary = BleStreamLogSummary { now }
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val work = (0..1).map {
                pool.submit {
                    repeat(100) { assertNull(summary.record(205)) }
                }
            }
            work.forEach { it.get(3, java.util.concurrent.TimeUnit.SECONDS) }
            now = 5_000L
            assertEquals("packets=201, bytes=41205, windowMs=5000", summary.record(205))
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun `audio window counts every packet and byte and resets after five seconds`() {
        var now = 0L
        val summary = BleStreamLogSummary { now }
        repeat(100) {
            assertNull(summary.record(205))
            now += 50
        }
        assertEquals("packets=101, bytes=20705, windowMs=5000", summary.record(205))
        now += 50
        assertNull(summary.record(100))
        now += 5_000
        assertEquals("packets=2, bytes=400, windowMs=5000", summary.record(300))
    }

    @Test
    fun `new callback lifetime starts a fresh window without prior audio counts`() {
        var now = 0L
        val old = BleStreamLogSummary { now }
        old.record(205)
        now = 9_000
        val fresh = BleStreamLogSummary { now }
        assertNull(fresh.record(3))
        now += 5_000
        assertEquals("packets=2, bytes=7, windowMs=5000", fresh.record(4))
    }
}
