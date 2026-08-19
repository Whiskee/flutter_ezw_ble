package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BleAndroidOtaWriteQueueTest {

    @Test
    fun `busy raw packet waits for the active gatt callback then retries the same bytes`() {
        val submissions = mutableListOf<ByteArray>()
        val dispositions = ArrayDeque(
            listOf(
                BleOtaWriteSubmission.busy(status = 201, reason = "GATT write request busy"),
                BleOtaWriteSubmission.accepted(),
            ),
        )
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = { data ->
                submissions.add(data.copyOf())
                dispositions.removeFirst()
            },
        )
        val rawPacket = byteArrayOf(0x01, 0x23, 0x45, 0x67)

        queue.enqueue(rawPacket) { completions.add(it) }

        assertEquals(1, submissions.size)
        assertEquals(1, queue.queueDepth)
        assertEquals(emptyList(), completions)

        // The callback belongs to the write that made Android return BUSY. It only opens the slot;
        // the retried OTA packet must still wait for its own callback before completing Dart await.
        queue.onCharacteristicWriteComplete(
            ownsInFlight = false,
            success = true,
            status = 0,
            statusName = "GATT_SUCCESS",
        )

        assertEquals(2, submissions.size)
        assertContentEquals(rawPacket, submissions[1])
        assertEquals(emptyList(), completions)

        queue.onCharacteristicWriteComplete(
            ownsInFlight = true,
            success = true,
            status = 0,
            statusName = "GATT_SUCCESS",
        )

        assertEquals(0, queue.queueDepth)
        assertEquals(1, completions.size)
        assertNull(completions.single())
    }

    @Test
    fun `accepted packets stay serialized by their characteristic write callbacks`() {
        val submissions = mutableListOf<ByteArray>()
        val completions = mutableListOf<Pair<Int, BleOtaWriteError?>>()
        val queue = queue(
            submit = { data ->
                submissions.add(data.copyOf())
                BleOtaWriteSubmission.accepted()
            },
        )

        queue.enqueue(byteArrayOf(0x01)) { completions.add(1 to it) }
        queue.enqueue(byteArrayOf(0x02)) { completions.add(2 to it) }

        assertEquals(1, submissions.size)
        assertEquals(2, queue.queueDepth)

        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")

        assertEquals(2, submissions.size)
        assertContentEquals(byteArrayOf(0x02), submissions[1])
        assertEquals(listOf(1), completions.map { it.first })

        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")

        assertEquals(listOf(1, 2), completions.map { it.first })
        assertEquals(0, queue.queueDepth)
    }

    @Test
    fun `busy write fails closed after the bounded stall window`() {
        var nowMillis = 0L
        val scheduler = FakeScheduler()
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = {
                BleOtaWriteSubmission.busy(status = 201, reason = "GATT write request busy")
            },
            scheduler = scheduler,
            nowMillis = { nowMillis },
        )

        queue.enqueue(byteArrayOf(0x7f)) { completions.add(it) }
        nowMillis = 4_000L
        scheduler.runNext()

        val error = completions.single()
        assertEquals("ota_write_stalled", error?.code)
        assertEquals(201, error?.details?.get("status"))
        assertEquals(4.0, error?.details?.get("wait"))
        assertEquals(0, queue.queueDepth)
    }

    @Test
    fun `teardown cancels both in flight and pending dart awaits`() {
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = { BleOtaWriteSubmission.accepted() },
        )

        queue.enqueue(byteArrayOf(0x01)) { completions.add(it) }
        queue.enqueue(byteArrayOf(0x02)) { completions.add(it) }
        queue.cancelAll("disconnect")

        assertEquals(2, completions.size)
        assertEquals(listOf("ota_write_cancelled", "ota_write_cancelled"), completions.map { it?.code })
        assertEquals(0, queue.queueDepth)
    }

    @Test
    fun `cancelled in flight callback only drains old slot and cannot complete retry`() {
        val submissions = mutableListOf<ByteArray>()
        val oldCompletions = mutableListOf<BleOtaWriteError?>()
        val retryCompletions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = { data ->
                submissions.add(data.copyOf())
                BleOtaWriteSubmission.accepted()
            },
        )

        queue.enqueue(byteArrayOf(0x01)) { oldCompletions.add(it) }
        queue.cancelAttempt("quiteUpgradeState")
        queue.enqueue(byteArrayOf(0x02)) { retryCompletions.add(it) }

        assertEquals(1, submissions.size, "retry must not submit before the cancelled callback drains")
        assertEquals("ota_write_cancelled", oldCompletions.single()?.code)
        assertEquals(emptyList(), retryCompletions)

        // Hostile timeline: this callback belongs to the cancelled packet. It may only open the
        // GATT slot; reverting the drain barrier would make it complete the retry packet here.
        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")

        assertEquals(2, submissions.size)
        assertContentEquals(byteArrayOf(0x02), submissions[1])
        assertEquals(emptyList(), retryCompletions)

        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")

        assertEquals(1, retryCompletions.size)
        assertNull(retryCompletions.single())
        assertEquals(0, queue.queueDepth)
    }

    @Test
    fun `missing cancelled callback stalls retry without reusing the occupied gatt slot`() {
        var nowMillis = 0L
        val scheduler = FakeScheduler()
        val submissions = mutableListOf<ByteArray>()
        val retryCompletions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = { data ->
                submissions.add(data.copyOf())
                BleOtaWriteSubmission.accepted()
            },
            scheduler = scheduler,
            nowMillis = { nowMillis },
        )

        queue.enqueue(byteArrayOf(0x01)) {}
        queue.cancelAttempt("quiteUpgradeState")
        queue.enqueue(byteArrayOf(0x02)) { retryCompletions.add(it) }
        nowMillis = 4_000L
        scheduler.runNext()

        assertEquals(1, submissions.size)
        assertEquals("ota_write_stalled", retryCompletions.single()?.code)

        // Even after the waiting retry fails, the physical slot is not reusable until the old
        // callback arrives. Draining it allows a later attempt to submit safely.
        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")
        queue.enqueue(byteArrayOf(0x03)) {}
        assertEquals(2, submissions.size)
        assertContentEquals(byteArrayOf(0x03), submissions[1])
    }

    @Test
    fun `failed characteristic callback reports the native status once`() {
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = { BleOtaWriteSubmission.accepted() },
        )

        queue.enqueue(byteArrayOf(0x01)) { completions.add(it) }
        queue.onCharacteristicWriteComplete(
            ownsInFlight = true,
            success = false,
            status = 133,
            statusName = "GATT_ERROR",
        )

        val error = completions.single()
        assertEquals("ota_write_unavailable", error?.code)
        assertEquals(133, error?.details?.get("status"))
        assertEquals("GATT_ERROR", error?.details?.get("statusName"))
        assertEquals(0, queue.queueDepth)
    }

    @Test
    fun `batch completes only after the last characteristic write callback`() {
        val submissions = mutableListOf<ByteArray>()
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = { data ->
                submissions.add(data.copyOf())
                BleOtaWriteSubmission.accepted()
            },
        )

        queue.enqueueBatch(
            listOf(byteArrayOf(0x01), byteArrayOf(0x02), byteArrayOf(0x03)),
        ) { completions.add(it) }

        assertEquals(1, submissions.size)
        assertEquals(emptyList(), completions)

        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")
        assertEquals(2, submissions.size)
        assertEquals(emptyList(), completions)

        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")
        assertEquals(3, submissions.size)
        assertEquals(emptyList(), completions)

        queue.onCharacteristicWriteComplete(true, true, 0, "GATT_SUCCESS")
        assertEquals(listOf<BleOtaWriteError?>(null), completions)
        assertEquals(0, queue.queueDepth)
    }

    @Test
    fun `batch failure drops remaining packets and settles once`() {
        val submissions = mutableListOf<ByteArray>()
        val completions = mutableListOf<BleOtaWriteError?>()
        val queue = queue(
            submit = { data ->
                submissions.add(data.copyOf())
                BleOtaWriteSubmission.accepted()
            },
        )

        queue.enqueueBatch(
            listOf(byteArrayOf(0x01), byteArrayOf(0x02), byteArrayOf(0x03)),
        ) { completions.add(it) }

        queue.onCharacteristicWriteComplete(
            ownsInFlight = true,
            success = false,
            status = 133,
            statusName = "GATT_ERROR",
        )

        assertEquals(1, submissions.size)
        assertEquals(1, completions.size)
        assertEquals("ota_write_unavailable", completions.single()?.code)
        assertEquals(0, queue.queueDepth)
    }

    private fun queue(
        submit: (ByteArray) -> BleOtaWriteSubmission,
        scheduler: BleOtaWriteScheduler = FakeScheduler(),
        nowMillis: () -> Long = { 0L },
    ): BleAndroidOtaWriteQueue = BleAndroidOtaWriteQueue(
        endpoint = "g2-left",
        submit = submit,
        scheduler = scheduler,
        nowMillis = nowMillis,
    )

    private class FakeScheduler : BleOtaWriteScheduler {
        private val tasks = ArrayDeque<FakeTask>()

        override fun schedule(delayMillis: Long, block: () -> Unit): BleOtaWriteCancellable {
            val task = FakeTask(block)
            tasks.addLast(task)
            return task
        }

        fun runNext() {
            // Production coroutine cancellation removes obsolete watchdog work. The fake keeps
            // entries for determinism, so skip cancelled tasks and execute the next live one.
            while (tasks.isNotEmpty()) {
                val task = tasks.removeFirst()
                if (!task.isCancelled) {
                    task.block()
                    return
                }
            }
            error("No active scheduled task")
        }
    }

    private class FakeTask(val block: () -> Unit) : BleOtaWriteCancellable {
        var isCancelled = false

        override fun cancel() {
            isCancelled = true
        }
    }
}
