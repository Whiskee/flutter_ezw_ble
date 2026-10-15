package com.fzfstudio.ezw_ble.ble

import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Fake main queue exercises scheduling without allowing a worker to touch a Flutter sink. */
class BleMainEventOutboxTest {
    private class Harness(maxBatch: Int = 64) {
        var now = 0L
        val posts = ArrayDeque<Runnable>()
        val events = mutableListOf<Pair<BleEC, Any>>()
        val metrics = mutableListOf<Triple<Long, Int, Int>>()
        val failures = mutableListOf<Throwable>()
        var delivery: (BleEC, Any) -> Unit = { channel, payload -> events.add(channel to payload) }
        var report: (Long, Int, Int) -> Unit = { age, sent, remaining -> metrics.add(Triple(age, sent, remaining)) }
        val outbox = BleMainEventOutbox(
            post = { posts.addLast(it) }, nowMillis = { now }, maxBatch = maxBatch,
            deliver = { channel, payload -> delivery(channel, payload) },
            onDrained = { age, sent, remaining -> report(age, sent, remaining) },
            onFailure = { failures.add(it) },
        )
        fun drain() = posts.removeFirst().run()
    }

    @Test
    fun `cross channel events share one post and retain FIFO`() {
        val h = Harness()
        val expected: List<Pair<BleEC, Any>> = listOf(BleEC.RECEIVE_DATA to "packet", BleEC.LOGGER to "log", BleEC.CONNECT_STATUS to "connected")
        expected.forEach { (channel, payload) -> h.outbox.emit(channel, payload) }
        assertEquals(1, h.posts.size)
        assertTrue(h.events.isEmpty())
        h.drain()
        assertEquals(expected, h.events)
        assertTrue(h.posts.isEmpty())
    }

    @Test
    fun `sink emission during drain joins FIFO without another post`() {
        val h = Harness()
        h.delivery = { channel, payload ->
            h.events.add(channel to payload)
            if (payload == 1) h.outbox.emit(BleEC.LOGGER, 3)
        }
        h.outbox.emit(BleEC.RECEIVE_DATA, 1)
        h.outbox.emit(BleEC.RECEIVE_DATA, 2)
        h.drain()
        assertEquals(listOf(1, 2, 3), h.events.map { it.second })
        assertTrue(h.posts.isEmpty())
    }

    @Test
    fun `bounded batches yield and repost exactly once`() {
        val h = Harness(maxBatch = 2)
        repeat(5) { h.outbox.emit(BleEC.RECEIVE_DATA, it) }
        h.drain()
        assertEquals(listOf(0, 1), h.events.map { it.second })
        assertEquals(1, h.posts.size)
        assertEquals(Triple(0L, 2, 3), h.metrics.single())
        h.drain()
        h.drain()
        assertEquals((0..4).toList(), h.events.map { it.second })
        assertTrue(h.posts.isEmpty())
    }

    @Test
    fun `sink failures do not reorder later events`() {
        val h = Harness()
        h.delivery = { channel, payload ->
            if (payload == 1) throw IllegalStateException("bad sink")
            h.events.add(channel to payload)
        }
        repeat(3) { h.outbox.emit(BleEC.LOGGER, it) }
        h.drain()
        assertEquals(listOf(0, 2), h.events.map { it.second })
        assertEquals(1, h.failures.size)
        assertTrue(h.posts.isEmpty())
    }

    @Test
    fun `missing listener consumes event without blocking later listeners`() {
        val posts = ArrayDeque<Runnable>()
        val metrics = mutableListOf<Int>()
        val outbox = BleMainEventOutbox(
            post = { posts.addLast(it) }, nowMillis = { 0 },
            onDrained = { _, sent, _ -> metrics.add(sent) },
        )
        outbox.emit(BleEC.LOGGER, "no listener")
        outbox.emit(BleEC.RECEIVE_DATA, emptyMap<String, Any>())
        posts.removeFirst().run()
        assertEquals(listOf(2), metrics)
        assertTrue(posts.isEmpty())
    }

    @Test
    fun `oldest age excludes drain execution and uses current batch`() {
        val h = Harness(maxBatch = 1)
        h.outbox.emit(BleEC.LOGGER, 1)
        h.now = 100
        h.outbox.emit(BleEC.LOGGER, 2)
        h.now = 250
        h.delivery = { _, _ -> h.now += 10 }
        h.drain()
        h.drain()
        assertEquals(listOf(Triple(250L, 1, 1), Triple(160L, 1, 0)), h.metrics)
    }

    @Test
    fun `clear retains scheduled post and only sends later events`() {
        val h = Harness()
        h.outbox.emit(BleEC.LOGGER, "old")
        h.outbox.clear()
        h.outbox.emit(BleEC.LOGGER, "new")
        assertEquals(1, h.posts.size)
        h.drain()
        assertEquals(listOf("new"), h.events.map { it.second })
    }

    @Test
    fun `clear during sink removes remaining old events and retains new ones`() {
        val h = Harness()
        h.delivery = { channel, payload ->
            h.events.add(channel to payload)
            if (payload == 1) {
                h.outbox.clear()
                h.outbox.emit(BleEC.LOGGER, 3)
            }
        }
        h.outbox.emit(BleEC.LOGGER, 1)
        h.outbox.emit(BleEC.LOGGER, 2)
        h.drain()
        assertEquals(listOf(1, 3), h.events.map { it.second })
        assertTrue(h.posts.isEmpty())
    }

    @Test
    fun `release retires queued and future events without touching new lifetime`() {
        val old = Harness()
        old.outbox.emit(BleEC.LOGGER, "old")
        old.outbox.release()
        old.outbox.emit(BleEC.LOGGER, "late")
        val fresh = Harness()
        fresh.outbox.emit(BleEC.LOGGER, "fresh")
        old.drain()
        fresh.drain()
        assertTrue(old.events.isEmpty())
        assertEquals(listOf("fresh"), fresh.events.map { it.second })
    }

    @Test
    fun `release racing delivery waits for in progress sink and prevents later calls`() {
        val h = Harness()
        val entered = CountDownLatch(1)
        val finishSink = CountDownLatch(1)
        val released = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        h.delivery = { channel, payload ->
            entered.countDown()
            check(finishSink.await(3, TimeUnit.SECONDS))
            h.events.add(channel to payload)
            // Reentrant release also proves queued items cannot escape after retirement.
            h.outbox.release()
        }
        h.outbox.emit(BleEC.LOGGER, 1)
        h.outbox.emit(BleEC.LOGGER, 2)
        try {
            val drain = pool.submit { h.drain() }
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            val release = pool.submit { h.outbox.release(); released.countDown() }
            assertEquals(1L, released.count)
            finishSink.countDown()
            drain.get(3, TimeUnit.SECONDS)
            release.get(3, TimeUnit.SECONDS)
            h.outbox.emit(BleEC.LOGGER, 3)
            assertEquals(listOf(1), h.events.map { it.second })
            assertTrue(h.posts.isEmpty())
        } finally {
            finishSink.countDown()
            pool.shutdownNow()
        }
    }

    @Test
    fun `report emission reposts once and reporter failure cannot wedge queue`() {
        val h = Harness(maxBatch = 1)
        h.report = { _, _, _ ->
            if (h.events.size == 1) h.outbox.emit(BleEC.LOGGER, 2)
            throw IllegalStateException("report failed")
        }
        h.outbox.emit(BleEC.LOGGER, 1)
        h.drain()
        assertEquals(1, h.posts.size)
        h.drain()
        assertEquals(listOf(1, 2), h.events.map { it.second })
        assertEquals(2, h.failures.size)
        assertTrue(h.posts.isEmpty())
    }

    @Test
    fun `concurrent producers keep bounded scheduling and nonnegative depth`() {
        val h = Harness(maxBatch = 7)
        val pool = Executors.newFixedThreadPool(4)
        try {
            val work = (0..3).map { producer -> pool.submit {
                repeat(100) { h.outbox.emit(BleEC.RECEIVE_DATA, producer * 100 + it) }
            } }
            work.forEach { it.get(3, TimeUnit.SECONDS) }
            assertEquals(1, h.posts.size)
            while (h.posts.isNotEmpty()) h.drain()
            assertEquals(400, h.events.map { it.second }.toSet().size)
            assertTrue(h.metrics.all { it.third >= 0 })
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun `clear racing producers preserves single scheduled drain and later events`() {
        val h = Harness(maxBatch = 7)
        val pool = Executors.newFixedThreadPool(3)
        val start = CountDownLatch(1)
        try {
            val work = (0..2).map { producer -> pool.submit {
                check(start.await(3, TimeUnit.SECONDS))
                repeat(100) {
                    if (producer == 2) h.outbox.clear()
                    else h.outbox.emit(BleEC.RECEIVE_DATA, producer * 100 + it)
                }
            } }
            start.countDown()
            work.forEach { it.get(3, TimeUnit.SECONDS) }
            h.outbox.emit(BleEC.LOGGER, "after-clear")
            assertEquals(1, h.posts.size)
            while (h.posts.isNotEmpty()) h.drain()
            assertEquals("after-clear", h.events.last().second)
            assertTrue(h.metrics.all { it.third >= 0 })
        } finally {
            start.countDown()
            pool.shutdownNow()
        }
    }

    @Test
    fun `invalid batch size fails immediately`() {
        assertFailsWith<IllegalArgumentException> { Harness(0) }
    }

    @Test
    fun `rejected post retries on next emission without reordering and broken diagnostics cannot wedge drain`() {
        val posts = ArrayDeque<Runnable>()
        val events = mutableListOf<Int>()
        var rejectsPost = true
        val outbox = BleMainEventOutbox(
            post = {
                if (rejectsPost) throw IllegalStateException("Looper rejected post")
                posts.addLast(it)
            }, nowMillis = { 0 },
            deliver = { _, payload ->
                if (payload == 1) throw IllegalStateException("sink rejected event")
                events.add(payload as Int)
            },
            onFailure = { throw IllegalStateException("diagnostic failure") },
        )
        outbox.emit(BleEC.LOGGER, 0)
        assertTrue(posts.isEmpty())
        rejectsPost = false
        outbox.emit(BleEC.LOGGER, 1)
        outbox.emit(BleEC.LOGGER, 2)
        assertEquals(1, posts.size)
        posts.removeFirst().run()
        assertEquals(listOf(0, 2), events)
        outbox.emit(BleEC.LOGGER, 3)
        posts.removeFirst().run()
        assertEquals(listOf(0, 2, 3), events)
    }
}
