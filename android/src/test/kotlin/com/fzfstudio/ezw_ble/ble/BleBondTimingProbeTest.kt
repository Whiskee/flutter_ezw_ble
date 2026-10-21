package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Executes the production sampler/ledger with deterministic clocks and escaped timer callbacks. */
class BleBondTimingProbeTest {
    @Test
    fun `disabled probe does not read schedule emit or create windows`() {
        val f = Fixture()
        f.enabled = false
        f.start()
        f.probe.record("AA", "receiver_main")
        assertEquals(0, f.reads)
        assertTrue(f.tasks.isEmpty())
        assertTrue(f.events.isEmpty())
        assertTrue(f.probe.isIdle())
    }

    @Test
    fun `reads every 100 ms and logs only first value and changes`() {
        val f = Fixture()
        f.start()
        f.advanceTo(0)
        f.advanceTo(299)
        assertEquals(3, f.reads)
        assertEquals(listOf(11), f.stage("public_bond_state").map { it["bondState"] })
        f.state = 12
        f.advanceTo(300)
        f.advanceTo(500)
        assertEquals(6, f.reads)
        assertEquals(listOf(11, 12), f.stage("public_bond_state").map { it["bondState"] })
        assertEquals(11, f.stage("public_bond_state").last()["previousBondState"])
        assertEquals(true, f.stage("public_bond_state").last()["getterMayBeCached"])
    }

    @Test
    fun `15 second deadline stops new reads and retires its diagnostic timer`() {
        val f = Fixture()
        f.start()
        f.advanceTo(20_000)
        assertEquals(150, f.reads)
        assertTrue(f.probe.isIdle())
        assertEquals("deadline", f.stage("probe_stop").single()["reason"])
        assertEquals(15_000_000_000L, f.stage("probe_stop").single()["monoNs"])
        assertEquals(1, f.idleCalls)
    }

    @Test
    fun `same exact owner is idempotent and replaced attempt rejects escaped old task`() {
        val f = Fixture()
        f.start()
        val escapedOldTask = f.tasks.single().action
        f.start()
        assertEquals(1, f.stage("probe_start").size)
        f.start(sessionId = 2L)
        val newId = f.stage("probe_start").last()["probeId"]
        escapedOldTask()
        assertEquals(0, f.reads)
        f.advanceTo(0)
        assertEquals(1, f.reads)
        assertEquals(newId, f.stage("public_bond_state").single()["probeId"])
        assertEquals("admission_replaced", f.stage("probe_stop").single()["reason"])
        // A late teardown belonging to session 1 cannot retire its replacement.
        f.probe.stop("AA", "old_cancel", 1L)
        assertFalse(f.probe.isIdle())
    }

    @Test
    fun `cancel reset and disabled escaped callbacks never read again`() {
        for (reason in listOf("admission_removed", "bluetooth_off", "release")) {
            val f = Fixture()
            f.start()
            val escaped = f.tasks.single().action
            f.probe.stopAll(reason)
            escaped()
            f.advanceTo(1_000)
            assertEquals(0, f.reads, reason)
            assertTrue(f.probe.isIdle(), reason)
        }
        val f = Fixture()
        f.start()
        val escaped = f.tasks.single().action
        f.enabled = false
        escaped()
        assertEquals(0, f.reads)
        assertTrue(f.probe.isIdle())
    }

    @Test
    fun `producer timestamps survive delayed logging and a wall clock jump`() {
        val f = Fixture()
        f.start()
        val frozenReceiverEntry = BleBondTimingStamp(10_000_000L, 50_010L, "receiver:7")
        f.nowMs = 800L
        f.wallOffset = 123_000L
        f.probe.record("aa", "receiver_main", frozenReceiverEntry, fields = mapOf("bondState" to 12))
        val event = f.stage("receiver_main").single()
        assertEquals(10_000_000L, event["monoNs"])
        assertEquals(50_010L, event["wallMs"])
        assertEquals("receiver:7", event["thread"])
        f.probe.record("AA", "manager_entry")
        val manager = f.stage("manager_entry").single()
        assertEquals(50_800L, manager["wallMs"])
        assertEquals(173_800L, manager["rawWallMs"])
        assertEquals(50_000L, manager["anchorWallMs"])
    }

    @Test
    fun `public getter errors are observable deduplicated and recover without BLE control`() {
        val f = Fixture()
        f.failure = SecurityException("BLUETOOTH_CONNECT denied")
        f.start()
        f.advanceTo(300)
        assertEquals(4, f.reads)
        assertEquals(1, f.stage("public_bond_read_error").size)
        assertTrue((f.stage("public_bond_read_error").single()["error"] as String).contains("SecurityException"))
        f.failure = null
        f.advanceTo(400)
        assertEquals(11, f.stage("public_bond_state").single()["bondState"])
        assertFalse(f.probe.isIdle())
    }

    @Test
    fun `observer errors do not suppress later receiver evidence and wrong sessions are filtered`() {
        val f = Fixture()
        f.start()
        f.probe.recordAll("observer_register_error", mapOf("error" to "SecurityException"))
        f.probe.record("AA", "receiver_background", sessionId = 9L)
        assertTrue(f.stage("receiver_background").isEmpty())
        f.probe.record("AA", "receiver_background", sessionId = 1L, fields = mapOf("bondState" to 12))
        assertEquals(1, f.stage("observer_register_error").size)
        assertEquals(1, f.stage("receiver_background").size)
    }

    @Test
    fun `receiver entry token cannot be attributed to replacement at the same clock tick`() {
        val f = Fixture()
        f.start()
        val oldEntry = f.probe.capture(BleBondTimingStamp(0L, 50_000L, "receiver:7"))
        f.probe.stop("AA", "cancelled", 1L)
        f.start(sessionId = 2L)
        f.probe.record("AA", "receiver_main", oldEntry, fields = mapOf("bondState" to 12))
        assertTrue(f.stage("receiver_main").isEmpty())
        val newEntry = f.probe.capture(BleBondTimingStamp(0L, 50_000L, "receiver:7"))
        f.probe.record("AA", "receiver_main", newEntry, fields = mapOf("bondState" to 12))
        assertEquals(2L, f.stage("receiver_main").single()["sessionId"])
        // The time guard also rejects a timestamp captured before a window existed.
        f.probe.record("AA", "receiver_background", BleBondTimingStamp(-1L, 49_999L, "receiver:8"))
        assertTrue(f.stage("receiver_background").isEmpty())
    }

    @Test
    fun `manager stages retain receiver token across replacement and clear context on exception`() {
        val f = Fixture()
        f.start()
        val entry = f.probe.capture(BleBondTimingStamp(0L, 50_000L, "receiver:7"))
        f.probe.stop("AA", "cancelled", 1L)
        f.start(sessionId = 2L)
        runCatching {
            BleBondTimingProbe.withReceiverStamp(entry) {
                // A freshly captured Manager stage still belongs to the old receiver's window.
                val current = f.probe.capture(BleBondTimingStamp(10L, 50_000L, "receiver:7"))
                f.probe.record("AA", "manager_entry", BleBondTimingProbe.inheritReceiverTokens(current))
                error("callback failure must retain its original propagation")
            }
        }
        assertTrue(f.stage("manager_entry").isEmpty())
        val next = f.probe.capture(BleBondTimingStamp(20L, 50_000L, "receiver:7"))
        f.probe.record("AA", "manager_entry", BleBondTimingProbe.inheritReceiverTokens(next))
        assertEquals(2L, f.stage("manager_entry").single()["sessionId"])
        assertEquals(20L, f.stage("manager_entry").single()["monoNs"])
    }

    @Test
    fun `discovery tail stops getters but retains late background evidence for one second`() {
        val f = Fixture()
        f.start()
        f.advanceTo(100)
        val escapedRead = f.tasks.last().action
        f.probe.finishAfterDiscovery("AA", 1L)
        f.state = 12
        escapedRead()
        f.advanceTo(200)
        f.probe.record("AA", "receiver_background", fields = mapOf("bondState" to 12))
        f.advanceTo(1_100)
        assertEquals(2, f.reads)
        assertEquals(1, f.stage("receiver_background").size)
        assertEquals(1_000L, f.stage("probe_tail").single()["tailMs"])
        assertEquals("discovery_tail_complete", f.stage("probe_stop").single()["reason"])
        assertTrue(f.probe.isIdle())
    }

    @Test
    fun `discovery tail obeys original deadline and immediate cancellation`() {
        val f = Fixture()
        f.start()
        f.advanceTo(14_900)
        f.probe.finishAfterDiscovery("AA", 1L)
        assertEquals(100L, f.stage("probe_tail").single()["tailMs"])
        f.advanceTo(15_000)
        assertTrue(f.probe.isIdle())
        val g = Fixture()
        g.start()
        g.probe.finishAfterDiscovery("AA", 1L)
        val escapedTail = g.tasks.last().action
        g.probe.stop("AA", "cancelled", 1L)
        g.start(sessionId = 2L)
        escapedTail()
        assertFalse(g.probe.isIdle())
    }

    @Test
    fun `logger and scheduler failures never throw into the caller`() {
        val f = Fixture()
        f.throwLog = true
        f.start()
        f.advanceTo(100)
        assertEquals(2, f.reads)
        f.probe.stopAll("release")
        assertTrue(f.probe.isIdle())
        val g = Fixture()
        g.rejectSchedule = true
        g.start()
        assertTrue(g.probe.isIdle())
        assertEquals(1, g.stage("sampler_schedule_error").size)
        assertEquals("sampler_unavailable", g.stage("probe_stop").single()["reason"])
    }

    /** A fake asynchronous queue models cancellation separately from tasks already in flight. */
    private class Fixture {
        data class Task(val dueMs: Long, val action: () -> Unit, var cancelled: Boolean = false)
        var enabled = true
        var nowMs = 0L
        var wallOffset = 0L
        var state = 11
        var failure: Throwable? = null
        var reads = 0
        var idleCalls = 0
        var throwLog = false
        var rejectSchedule = false
        val tasks = mutableListOf<Task>()
        val events = mutableListOf<Map<String, Any?>>()
        val probe = BleBondTimingProbe(
            enabled = { enabled },
            clock = { BleBondTimingStamp(nowMs * 1_000_000L, 50_000L + nowMs + wallOffset, "test:1") },
            schedule = { delay, action ->
                check(!rejectSchedule) { "scheduler rejected" }
                val task = Task(nowMs + delay, action)
                tasks += task
                BleBondTimingCancellation { task.cancelled = true }
            },
            emit = { if (throwLog) error("logger unavailable") else events += it },
            onIdle = { idleCalls++ },
        )

        fun start(sessionId: Long = 1L) = probe.start(
            BleBondTimingOwner("AA", "G2", 101L, sessionId, sessionId),
        ) { reads++; failure?.let { throw it }; state }

        fun stage(stage: String): List<Map<String, Any?>> = events.filter { it["stage"] == stage }

        fun advanceTo(target: Long) {
            while (true) {
                val next = tasks.filter { !it.cancelled && it.dueMs <= target }.minByOrNull { it.dueMs } ?: break
                tasks.remove(next)
                nowMs = next.dueMs
                next.action()
            }
            nowMs = target
        }
    }
}
