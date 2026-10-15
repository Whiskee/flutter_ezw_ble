package com.fzfstudio.ezw_ble.ble

import android.util.Log
import java.util.ArrayDeque

/**
 * Native → Dart 的单一主线程出口：一条 Looper 消息最多交付 [maxBatch] 个原有事件。
 *
 * Flutter 合并平台/Dart 线程后，逐包 post 会在繁忙 Dart 任务之间堆积 Java 消息。
 * 三类事件共用 FIFO，保留每包 payload 与入队顺序，只合并调度，不合并数据包。
 * 队列、调度位与释放位共用一个锁，避免先 poll 后计数、clear 和 emit 之间的竞态。
 */
internal class BleMainEventOutbox(
    private val post: (Runnable) -> Unit,
    private val nowMillis: () -> Long,
    private val maxBatch: Int = 64,
    private val deliver: (BleEC, Any) -> Unit = { channel, payload ->
        channel.event?.success(payload)
    },
    private val onDrained: (oldestAgeMs: Long, sent: Int, remaining: Int) -> Unit = { _, _, _ -> },
    private val onFailure: (Throwable) -> Unit = {
        // 失败诊断只能写 logcat；再次入 LOGGER 会把坏 sink 变成自激队列。
        Log.e("BleMainEventOutbox", "Native event delivery failed", it)
    },
) {
    private data class Pending(val channel: BleEC, val payload: Any, val enqueuedAt: Long)

    private val lock = Any()
    private val queue = ArrayDeque<Pending>()
    private var drainScheduled = false
    private var released = false
    private val drain = Runnable { drainOnce() }

    init {
        require(maxBatch > 0) { "maxBatch must be positive" }
    }

    /** Payload/identity 已由生产线程冻结；这里不能重新查询当前 GATT owner。 */
    fun emit(channel: BleEC, payload: Any) = synchronized(lock) {
        if (released) return@synchronized
        queue.addLast(Pending(channel, payload, nowMillis()))
        scheduleLocked()
    }

    /** 清空待发事件但复用已 post 的 drain，不能制造第二条挂起消息。 */
    fun clear() = synchronized(lock) { queue.clear() }

    /** 退休一个 engine lifetime；旧 Runnable 即使迟到也不能消费新 lifetime 的队列。 */
    fun release() = synchronized(lock) {
        released = true
        queue.clear()
    }

    private fun scheduleLocked() {
        if (released || drainScheduled || queue.isEmpty()) return
        drainScheduled = true
        try {
            post(drain)
        } catch (error: Exception) {
            drainScheduled = false
            reportFailure(error)
        }
    }

    private fun drainOnce() = synchronized(lock) {
        if (released) {
            drainScheduled = false
            return@synchronized
        }
        // 时长在开始交付时冻结，不把本批 sink 调用耗时算成排队时间。
        val oldestAge = queue.peekFirst()?.let { (nowMillis() - it.enqueuedAt).coerceAtLeast(0L) }
        var sent = 0
        try {
            while (!released && sent < maxBatch) {
                val item = queue.pollFirst() ?: break
                // 与 release 共锁：release 返回后不会再开始一次旧 sink 调用。
                try {
                    deliver(item.channel, item.payload)
                } catch (error: Exception) {
                    reportFailure(error)
                }
                sent++
            }
            if (!released && oldestAge != null) {
                try {
                    onDrained(oldestAge, sent, queue.size)
                } catch (error: Exception) {
                    reportFailure(error)
                }
            }
        } finally {
            drainScheduled = false
            // sink/onDrained 可重入 emit；保持同一 FIFO 并为剩余事件只补一条消息。
            scheduleLocked()
        }
    }

    private fun reportFailure(error: Throwable) {
        // 诊断回调失败同样不能中断后续包或让 drainScheduled 永久为 true。
        runCatching { onFailure(error) }
    }
}
