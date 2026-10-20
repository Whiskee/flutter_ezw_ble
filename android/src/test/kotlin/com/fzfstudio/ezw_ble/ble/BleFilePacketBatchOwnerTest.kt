package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Exercise native ownership at the real queue boundary, without an OS or firmware ACK claim. */
class BleFilePacketBatchOwnerTest {
    @Test
    fun `cancel before submission retires reservation and delayed send cannot resurrect it`() {
        val f = Fixture()
        val token = assertNotNull(f.queue.beginFilePacketBatch())
        assertNull(f.queue.beginFilePacketBatch(), "only one live reservation is allowed")
        assertTrue(f.queue.cancelFilePacketBatch(token))
        assertFalse(f.queue.cancelFilePacketBatch(token))
        f.send(token, 1, 2)
        assertEquals(listOf("file_write_unavailable"), f.results.map { it?.code })
        assertEquals(emptyList(), f.submitted)
        assertNotEquals(token, assertNotNull(f.queue.beginFilePacketBatch()))
    }

    @Test
    fun `partial cancellation retains GATT drain barrier and unrelated legacy batch`() {
        val f = Fixture()
        val token = assertNotNull(f.queue.beginFilePacketBatch())
        f.send(token, 1, 2, 3)
        val legacy = mutableListOf<BleOtaWriteError?>()
        f.queue.enqueueBatch(listOf(byteArrayOf(7), byteArrayOf(8))) { legacy += it }
        assertEquals(listOf(1), f.submitted)

        assertTrue(f.queue.cancelFilePacketBatch(token))
        assertEquals("file_write_cancelled", f.results.single()?.code)
        assertEquals(2, f.queue.queueDepth)
        assertTrue(f.queue.hasOutstandingGattWrite)
        assertEquals(listOf(1), f.submitted, "cancel cannot release an OS-submitted write")
        f.callback()
        assertEquals(listOf(1, 7), f.submitted)
        assertEquals(emptyList(), legacy)
        f.callback()
        f.callback()
        assertEquals(listOf<BleOtaWriteError?>(null), legacy)
        assertEquals(listOf(1, 7, 8), f.submitted)
    }

    @Test
    fun `unknown cross endpoint and duplicate token fail closed without cancelling current owner`() {
        val f = Fixture()
        val other = Fixture(endpoint = "other")
        val token = assertNotNull(f.queue.beginFilePacketBatch())
        other.send(token, 9)
        assertEquals("file_write_unavailable", other.results.single()?.code)
        assertFalse(other.queue.cancelFilePacketBatch(token))
        assertFalse(f.queue.cancelFilePacketBatch("unknown"))
        f.send(token, 1, 2)
        f.send(token, 3)
        assertEquals("file_write_unavailable", f.results.single()?.code)
        f.callback()
        f.callback()
        assertEquals(listOf(1, 2), f.submitted)
        assertEquals(listOf("file_write_unavailable", null), f.results.map { it?.code })
        assertFalse(f.queue.cancelFilePacketBatch(token))
    }

    @Test
    fun `completion retires before callback can reserve and submit the next owner`() {
        val f = Fixture()
        val first = assertNotNull(f.queue.beginFilePacketBatch())
        var replacement: String? = null
        f.queue.enqueueBatch(listOf(byteArrayOf(1)), fileBatchToken = first) { error ->
            assertNull(error)
            replacement = assertNotNull(f.queue.beginFilePacketBatch())
            f.send(replacement, 2)
        }
        f.callback()
        assertNotEquals(first, replacement)
        assertFalse(f.queue.cancelFilePacketBatch(first))
        assertEquals(listOf(1, 2), f.submitted)
        assertEquals(emptyList(), f.results)
        f.callback()
        assertEquals(listOf<BleOtaWriteError?>(null), f.results)
    }

    @Test
    fun `cancellation retires before reentrant replacement and old callback cannot complete replacement`() {
        val f = Fixture()
        val first = assertNotNull(f.queue.beginFilePacketBatch())
        val cancelled = mutableListOf<BleOtaWriteError?>()
        f.queue.enqueueBatch(listOf(byteArrayOf(1), byteArrayOf(3)), fileBatchToken = first) { error ->
            cancelled += error
            f.send(assertNotNull(f.queue.beginFilePacketBatch()), 2)
        }
        assertTrue(f.queue.cancelFilePacketBatch(first))
        assertEquals("file_write_cancelled", cancelled.single()?.code)
        assertEquals(listOf(1), f.submitted)
        f.callback()
        assertEquals(listOf(1, 2), f.submitted)
        assertEquals(emptyList(), f.results)
        f.callback()
        assertEquals(listOf<BleOtaWriteError?>(null), f.results)
    }

    @Test
    fun `busy unsent cancellation removes only exact owner and stale timers cannot repeat it`() {
        val f = Fixture()
        f.busy = true
        val token = assertNotNull(f.queue.beginFilePacketBatch())
        f.send(token, 1, 2)
        assertTrue(f.queue.cancelFilePacketBatch(token))
        f.busy = false
        f.send(assertNotNull(f.queue.beginFilePacketBatch()), 3)
        f.scheduler.fireCancelled()
        assertEquals(listOf(3), f.submitted)
        f.callback()
        assertEquals(listOf("file_write_cancelled", null), f.results.map { it?.code })
        assertEquals(0, f.queue.queueDepth)
    }

    @Test
    fun `cancelled watchdog cannot retry or replace the new owners watchdog`() {
        val f = Fixture()
        f.busy = true
        val old = assertNotNull(f.queue.beginFilePacketBatch())
        f.send(old, 1)
        f.queue.cancelFilePacketBatch(old)
        f.send(assertNotNull(f.queue.beginFilePacketBatch()), 2)
        assertEquals(2, f.submissionAttempts)
        f.scheduler.fireCancelled()
        assertEquals(2, f.submissionAttempts, "a cancelled old task must not drive the replacement")
        f.busy = false
        f.scheduler.fireActive()
        assertEquals(listOf(2), f.submitted)
    }

    @Test
    fun `owned callback timeout retires token but preserves physical drain debt`() {
        val f = Fixture()
        val old = assertNotNull(f.queue.beginFilePacketBatch())
        f.send(old, 1, 2)
        f.now = 4_000L
        f.scheduler.fireActive()
        assertEquals("file_write_stalled", f.results.single()?.code)
        assertFalse(f.queue.cancelFilePacketBatch(old))
        f.send(assertNotNull(f.queue.beginFilePacketBatch()), 3)
        assertEquals(listOf(1), f.submitted)
        f.callback()
        assertEquals(listOf(1, 3), f.submitted)
        assertEquals(1, f.results.size)
        f.callback()
        assertEquals(listOf("file_write_stalled", null), f.results.map { it?.code })
    }

    @Test
    fun `cancel pending owner neither retries unrelated busy batch nor extends its timeout`() {
        val f = Fixture()
        f.busy = true
        f.send(null, 7)
        f.now = 3_000L
        val owned = assertNotNull(f.queue.beginFilePacketBatch())
        f.send(owned, 1)
        val attemptsBeforeCancel = f.submissionAttempts
        assertTrue(f.queue.cancelFilePacketBatch(owned))
        assertEquals(attemptsBeforeCancel, f.submissionAttempts)
        f.now = 4_000L
        f.scheduler.fireActive()
        assertEquals(listOf("file_write_cancelled", "file_write_stalled"), f.results.map { it?.code })
        assertEquals(emptyList(), f.submitted)
    }

    @Test
    fun `teardown revokes both empty and submitted reservations before completion`() {
        val empty = Fixture()
        val emptyToken = assertNotNull(empty.queue.beginFilePacketBatch())
        empty.queue.cancelAll("physical teardown")
        empty.send(emptyToken, 4)
        assertEquals(emptyList(), empty.submitted)

        val f = Fixture()
        val token = assertNotNull(f.queue.beginFilePacketBatch())
        f.send(token, 1, 2)
        f.queue.cancelAll("physical teardown")
        assertFalse(f.queue.hasOutstandingGattWrite, "physical teardown alone may discard drain debt")
        assertFalse(f.queue.cancelFilePacketBatch(token))
        f.send(token, 3)
        assertEquals(listOf("file_write_cancelled", "file_write_unavailable"), f.results.map { it?.code })
    }

    @Test
    fun `rejection retires owner before callback while omitted token remains supported`() {
        val f = Fixture()
        f.reject = true
        val token = assertNotNull(f.queue.beginFilePacketBatch())
        f.send(token, 1, 2)
        assertFalse(f.queue.cancelFilePacketBatch(token))
        val next = assertNotNull(f.queue.beginFilePacketBatch())
        f.reject = false
        f.send(next, 3)
        f.callback()
        f.send(null, 4)
        f.callback()
        assertEquals(listOf(3, 4), f.submitted)
        assertEquals(listOf("file_write_unavailable", null, null), f.results.map { it?.code })
    }

    /** Deterministic Android single-slot fake; the production queue retains every ownership rule. */
    private class Fixture(endpoint: String = "file-left") {
        val submitted = mutableListOf<Int>()
        val results = mutableListOf<BleOtaWriteError?>()
        val scheduler = Scheduler()
        var busy = false
        var reject = false
        var now = 0L
        var submissionAttempts = 0
        val queue = BleAndroidOtaWriteQueue(
            endpoint = endpoint,
            channel = BleWriteChannel.FILE,
            submit = { data, _, _, _, _, _ ->
                submissionAttempts += 1
                when {
                    reject -> BleOtaWriteSubmission.rejected(null, "target lost")
                    busy -> BleOtaWriteSubmission.busy(201, "busy")
                    else -> BleOtaWriteSubmission.accepted().also { submitted += data[0].toInt() }
                }
            },
            scheduler = scheduler,
            nowMillis = { now },
        )

        fun send(token: String?, vararg packets: Int) = queue.enqueueBatch(
            packets.map { byteArrayOf(it.toByte()) }, fileBatchToken = token,
        ) { results += it }

        fun callback() = queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")
    }

    /** Retain cancelled tasks deliberately to challenge stale callback ownership. */
    private class Scheduler : BleOtaWriteScheduler {
        private val cancelled = mutableListOf<() -> Unit>()
        private val active = mutableListOf<() -> Unit>()
        override fun schedule(delayMillis: Long, block: () -> Unit): BleOtaWriteCancellable {
            active += block
            return BleOtaWriteCancellable { active.remove(block); cancelled += block }
        }
        fun fireCancelled() = cancelled.toList().forEach { it() }
        fun fireActive() { val due = active.toList(); active.clear(); due.forEach { it() } }
    }
}
