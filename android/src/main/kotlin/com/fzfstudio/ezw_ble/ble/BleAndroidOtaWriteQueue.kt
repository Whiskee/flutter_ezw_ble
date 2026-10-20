package com.fzfstudio.ezw_ble.ble

import java.util.UUID

/** Android 对一次 `BluetoothGatt.writeCharacteristic` 同步提交的精确分类。 */
internal class BleOtaWriteSubmission private constructor(
    val disposition: Disposition,
    val status: Int?,
    val reason: String,
) {
    enum class Disposition {
        ACCEPTED,
        BUSY,
        REJECTED,
    }

    companion object {
        fun accepted(): BleOtaWriteSubmission =
            BleOtaWriteSubmission(Disposition.ACCEPTED, status = 0, reason = "submitted")

        fun busy(status: Int?, reason: String): BleOtaWriteSubmission =
            BleOtaWriteSubmission(Disposition.BUSY, status, reason)

        fun rejected(status: Int?, reason: String): BleOtaWriteSubmission =
            BleOtaWriteSubmission(Disposition.REJECTED, status, reason)
    }
}

/** 可取消的 OTA 背压检查任务；生产环境由 manager 的协程 Job 实现。 */
internal fun interface BleOtaWriteCancellable {
    fun cancel()
}

/** 可注入调度器让 Android OTA 背压与停滞行为能用纯 JVM 单测确定性覆盖。 */
internal fun interface BleOtaWriteScheduler {
    fun schedule(delayMillis: Long, block: () -> Unit): BleOtaWriteCancellable
}

/** Diagnostic-only counters for one native batch; absent values stay unknown to Dart. */
data class BleAndroidOtaBatchQueueMetrics(
    val backpressureCount: Int,
    val backpressureWaitMillis: Long,
    val softThrottleCount: Int,
)

/**
 * 单 endpoint、单通道的 Android 无应答批量写队列。
 *
 * Android 的 no-response 写仍然是单槽位 GATT 操作：同步 `SUCCESS` 只表示系统接受提交，
 * 真正释放下一包必须等 `onCharacteristicWrite`。同步 BUSY 是可恢复背压，原包保留到活动
 * 写回调或 watchdog 重试；取消 attempt 后还必须保留旧 callback 的 drain barrier，避免旧回调
 * 完成下一轮写入。其它错误、断连与超时均 fail closed，保证 Dart await 必有终态。
 *
 * OTA(psType=1) 与文件(psType=3) 各自持有独立实例，不共享 pending：退出升级只能取消 OTA
 * attempt，绝不能顺手清掉正在传输的文件批次。只有 FILE 可保留可精确撤销的 native token。
 */
internal class BleAndroidOtaWriteQueue(
    private val endpoint: String,
    private val submit: (ByteArray, Long, Long, String, Long, String) -> BleOtaWriteSubmission,
    private val scheduler: BleOtaWriteScheduler,
    private val nowMillis: () -> Long,
    private val logger: (String) -> Unit = {},
    private val channel: String = BleWriteChannel.OTA,
    private val fileTargetIsCurrent: () -> Boolean = { true },
    // Production uses Manager's admission/teardown monitor for every entry, including timers.
    // A separate Queue monitor would invert callback -> Manager against Manager -> cancel.
    private val stateLock: Any = Any(),
) {
    /** 一批 framed OTA 小包共享一个 Dart Future；成功只在最后一包 callback 后结算。 */
    private class OtaWriteBatch(
        val completion: (BleOtaWriteError?) -> Unit,
        var remaining: Int,
        val metrics: ((BleAndroidOtaBatchQueueMetrics) -> Unit)? = null,
        val fileBatchToken: String? = null,
        var settled: Boolean = false,
        var backpressureCount: Int = 0,
        var backpressureWaitMillis: Long = 0L,
    ) {
        fun settle(error: BleOtaWriteError?) {
            if (settled) {
                return
            }
            settled = true
            if (error == null) {
                metrics?.invoke(
                    BleAndroidOtaBatchQueueMetrics(
                        backpressureCount = backpressureCount,
                        backpressureWaitMillis = backpressureWaitMillis,
                        // Android serializes on GATT callbacks and has no CoreBluetooth-style
                        // soft throttle; report an explicit known zero only for measured batches.
                        softThrottleCount = 0,
                    ),
                )
            }
            completion(error)
        }
    }

    private data class Item(
        val data: ByteArray,
        val sessionGeneration: Long,
        val attemptGeneration: Long,
        val otaTransactionId: String,
        val otaGeneration: Long,
        val otaInstanceId: String,
        val completion: (BleOtaWriteError?) -> Unit,
        val batch: OtaWriteBatch? = null,
    )

    private val pending = ArrayDeque<Item>()
    private var inFlight: Item? = null
    // Android callback 不回传调用方 token；同一 GATT session 取消已提交写时，必须保留这个
    // 单槽位屏障，直到旧 callback 到达。新 attempt 只能排队，不能把旧 callback 当成自己的。
    private var cancelledInFlightCallbackPending = false
    private var waitStartedAtMillis: Long? = null
    private var waitContributesToBatchMetrics = false
    private var watchdog: BleOtaWriteCancellable? = null
    // Cancelled coroutine callbacks may already be queued; they cannot drive a new owner or
    // clear its watchdog handle after exact cancellation/completion has installed a replacement.
    private var watchdogGeneration = 0L
    private var lastBackpressure: BleOtaWriteSubmission? = null
    // One native reservation per endpoint; retiring it is sufficient to reject delayed sends,
    // without retaining an unbounded history of cancelled tokens across queue recreation.
    private var fileBatchToken: String? = null
    private var fileBatchSubmitted = false

    /** Reserve exactly one future FILE batch; native UUIDs do not repeat after teardown. */
    fun beginFilePacketBatch(): String? = synchronized(stateLock) {
        if (channel != BleWriteChannel.FILE || fileBatchToken != null || !fileTargetIsCurrent()) {
            return null
        }
        return UUID.randomUUID().toString().also {
            fileBatchToken = it
            fileBatchSubmitted = false
        }
    }

    /** Begin must not issue a fresh token from a retained queue for an already-replaced target. */
    val isFileTargetCurrent: Boolean
        get() = synchronized(stateLock) { fileTargetIsCurrent() }

    /** Admission failures before enqueue must also release their still-unused reservation. */
    fun retireUnsubmittedFilePacketBatch(token: String): Unit = synchronized(stateLock) {
        if (fileBatchToken == token && !fileBatchSubmitted) {
            retireFilePacketBatch(token)
        }
    }

    /**
     * Revoke before callbacks and remove only this owner's native-unsent tail. An OS-submitted
     * write cannot be retracted; its old callback remains a barrier for every replacement batch.
     */
    fun cancelFilePacketBatch(token: String): Boolean = synchronized(stateLock) {
        if (channel != BleWriteChannel.FILE || fileBatchToken != token) {
            return false
        }
        val ownsCurrentWait = inFlight?.batch?.fileBatchToken == token ||
            (inFlight == null && pending.firstOrNull()?.batch?.fileBatchToken == token)
        retireFilePacketBatch(token)
        val snapshot = buildList {
            inFlight?.takeIf { it.batch?.fileBatchToken == token }?.let(::add)
            addAll(pending.filter { it.batch?.fileBatchToken == token })
        }
        if (inFlight?.batch?.fileBatchToken == token) {
            inFlight = null
            cancelledInFlightCallbackPending = true
        }
        pending.removeAll { it.batch?.fileBatchToken == token }
        if (snapshot.isNotEmpty()) {
            // An owner queued behind an unrelated legacy write must not reset that write's
            // existing four-second watchdog or trigger an extra native BUSY retry.
            if (ownsCurrentWait) clearWait()
            completeSnapshot(
                snapshot,
                BleOtaWriteError.cancelled(endpoint, "file batch revoked", snapshot.size, channel),
            )
            if (ownsCurrentWait) pump()
        }
        return true
    }

    /** 包含已提交但尚未收到 GATT callback 的包，便于错误详情反映真实深度。 */
    val queueDepth: Int
        get() = synchronized(stateLock) { pending.size + if (inFlight == null) 0 else 1 }

    /** 当前 endpoint 是否仍占有物理 GATT 写槽；普通命令也必须等待该槽释放。 */
    val hasOutstandingGattWrite: Boolean
        get() = synchronized(stateLock) { inFlight != null || cancelledInFlightCallbackPending }

    /** 入队后立即尝试提交；成功回调只会在本包自己的 characteristic callback 后触发。 */
    fun enqueue(
        data: ByteArray,
        sessionGeneration: Long = 0L,
        attemptGeneration: Long = 0L,
        otaTransactionId: String = "",
        otaGeneration: Long = 0L,
        otaInstanceId: String = "",
        completion: (BleOtaWriteError?) -> Unit,
    ): Unit = synchronized(stateLock) {
        pending.addLast(
            Item(
                data = data.copyOf(),
                sessionGeneration = sessionGeneration,
                attemptGeneration = attemptGeneration,
                otaTransactionId = otaTransactionId,
                otaGeneration = otaGeneration,
                otaInstanceId = otaInstanceId,
                completion = completion,
            ),
        )
        logFileOnly { "[ezw_ble][$channel][android] enqueued endpoint=$endpoint bytes=${data.size} pending=$queueDepth" }
        pump()
    }

    /** 一批小包共享一个完成回调，但每包仍携带 exact OTA transaction identity。 */
    fun enqueueBatch(
        packets: List<ByteArray>,
        sessionGeneration: Long = 0L,
        attemptGeneration: Long = 0L,
        otaTransactionId: String = "",
        otaGeneration: Long = 0L,
        otaInstanceId: String = "",
        metrics: ((BleAndroidOtaBatchQueueMetrics) -> Unit)? = null,
        fileBatchToken: String? = null,
        completion: (BleOtaWriteError?) -> Unit,
    ): Unit = synchronized(stateLock) {
        if (fileBatchToken != null &&
            (channel != BleWriteChannel.FILE || this.fileBatchToken != fileBatchToken || fileBatchSubmitted)
        ) {
            completion(BleOtaWriteError.unavailable(endpoint, "unknown or consumed file batch token", channel = channel))
            return
        }
        if (packets.isEmpty()) {
            fileBatchToken?.let(::retireFilePacketBatch)
            completion(BleOtaWriteError.unavailable(endpoint, "empty batch", channel = channel))
            return
        }
        if (fileBatchToken != null) {
            fileBatchSubmitted = true
        }
        val batch = OtaWriteBatch(
            completion = completion,
            remaining = packets.size,
            metrics = metrics,
            fileBatchToken = fileBatchToken,
        )
        packets.forEach { packet ->
            pending.addLast(
                Item(
                    data = packet.copyOf(),
                    sessionGeneration = sessionGeneration,
                    attemptGeneration = attemptGeneration,
                    otaTransactionId = otaTransactionId,
                    otaGeneration = otaGeneration,
                    otaInstanceId = otaInstanceId,
                    completion = {},
                    batch = batch,
                ),
            )
        }
        logFileOnly {
            "[ezw_ble][$channel][android] batch enqueued endpoint=$endpoint " +
                "packets=${packets.size} bytes=${packets.sumOf { it.size }} pending=$queueDepth"
        }
        pump()
    }

    /**
     * 接收当前 GATT session 的写完成回调。
     *
     * [ownsInFlight] 由 manager 根据普通发送队列当前 head 与 characteristic psType 判定；
     * false 的回调只表示此前占用 GATT 的其它写已释放，可用于唤醒同步 BUSY 的 OTA 包。
     */
    fun onCharacteristicWriteComplete(
        ownsInFlight: Boolean,
        success: Boolean,
        status: Int,
        statusName: String,
    ): Boolean = synchronized(stateLock) {
        if (ownsInFlight) {
            if (cancelledInFlightCallbackPending) {
                // 这条 callback 只证明上一个已取消 attempt 的系统写槽已释放。此时新 attempt
                // 尚未提交，因此绝不能完成它的 Future；解除屏障后再驱动排队写入。
                cancelledInFlightCallbackPending = false
                clearWait()
                logger(
                    "[ezw_ble][$channel][android] drained cancelled callback " +
                        "endpoint=$endpoint status=$statusName pending=$queueDepth",
                )
                pump()
                return true
            }
            val completed = inFlight
            if (completed != null) {
                inFlight = null
                clearWait()
                if (success) {
                    if (completed.batch == null) {
                        logFileOnly { "[ezw_ble][$channel][android] completed endpoint=$endpoint status=$statusName pending=$queueDepth" }
                    }
                    completeItem(completed, error = null)
                } else {
                    logger("[ezw_ble][$channel][android] failed endpoint=$endpoint status=$statusName pending=$queueDepth")
                    completeItem(
                        completed,
                        BleOtaWriteError.unavailable(
                            endpoint = endpoint,
                            reason = "onCharacteristicWrite failed: $statusName",
                            pending = queueDepth,
                            status = status,
                            statusName = statusName,
                            channel = channel,
                        ),
                    )
                }
                pump()
                return true
            }
        } else if (inFlight == null && pending.isNotEmpty()) {
            // 前一笔普通/旧 OTA 写回调证明 GATT 单槽位已经释放，从头开始计算本包等待窗口。
            clearWait()
        }
        pump()
        return false
    }

    /**
     * 取消当前 OTA attempt，但保留同一 GATT session 已提交写的 callback 屏障。
     *
     * 退出升级不会关闭 GATT，Android 又无法在 callback 中回传本地 write token；因此只取消
     * Dart Future 不足以隔离下一轮 attempt，必须等旧 callback 被 drain 后才允许任何新写。
     */
    fun cancelAttempt(reason: String): Unit = synchronized(stateLock) {
        fileBatchToken = null
        fileBatchSubmitted = false
        val hadInFlight = inFlight != null
        val snapshot = buildList {
            inFlight?.let(::add)
            addAll(pending)
        }
        inFlight = null
        pending.clear()
        if (hadInFlight) {
            cancelledInFlightCallbackPending = true
        }
        clearWait()
        if (snapshot.isEmpty()) {
            return
        }
        logger("[ezw_ble][$channel][android] attempt cancelled endpoint=$endpoint reason=$reason pending=${snapshot.size}")
        completeSnapshot(
            snapshot,
            BleOtaWriteError.cancelled(
                endpoint = endpoint,
                reason = reason,
                pending = snapshot.size,
                channel = channel,
            ),
        )
    }

    /** 物理 GATT session 已失效时释放所有 Future，并丢弃旧 session 的 callback 屏障。 */
    fun cancelAll(reason: String): Unit = synchronized(stateLock) {
        // Empty reservations have no queued Item, but physical teardown must revoke them too.
        fileBatchToken = null
        fileBatchSubmitted = false
        val snapshot = buildList {
            inFlight?.let(::add)
            addAll(pending)
        }
        inFlight = null
        pending.clear()
        cancelledInFlightCallbackPending = false
        clearWait()
        if (snapshot.isEmpty()) {
            return
        }
        logger("[ezw_ble][$channel][android] cancelled endpoint=$endpoint reason=$reason pending=${snapshot.size}")
        completeSnapshot(
            snapshot,
            BleOtaWriteError.cancelled(
                endpoint = endpoint,
                reason = reason,
                pending = snapshot.size,
                channel = channel,
            ),
        )
    }

    /** 驱动同步提交；任何时刻最多只有一包处于已提交、等 callback 状态。 */
    private fun pump() {
        if (cancelledInFlightCallbackPending) {
            if (pending.isEmpty()) {
                clearWait()
                return
            }
            // 旧 callback 丢失时 fail closed 当前新 attempt，但继续保留 drain barrier；只有
            // 物理 session teardown 或旧 callback 到达，才允许后续 attempt 复用该 GATT。
            if (!failIfStalled("cancelled write callback timeout", lastBackpressure)) {
                scheduleWatchdog()
            }
            return
        }
        if (inFlight != null) {
            if (!failIfStalled("onCharacteristicWrite timeout", lastBackpressure)) {
                scheduleWatchdog()
            }
            return
        }

        while (pending.isNotEmpty()) {
            val head = pending.first()
            val submission = submit(
                head.data,
                head.sessionGeneration,
                head.attemptGeneration,
                head.otaTransactionId,
                head.otaGeneration,
                head.otaInstanceId,
            )
            when (submission.disposition) {
                BleOtaWriteSubmission.Disposition.ACCEPTED -> {
                    pending.removeFirst()
                    clearWait()
                    inFlight = head
                    waitStartedAtMillis = nowMillis()
                    lastBackpressure = null
                    logFileOnly { "[ezw_ble][$channel][android] submitted endpoint=$endpoint bytes=${head.data.size} pending=$queueDepth" }
                    scheduleWatchdog()
                    return
                }

                BleOtaWriteSubmission.Disposition.BUSY -> {
                    lastBackpressure = submission
                    head.batch?.backpressureCount = (head.batch?.backpressureCount ?: 0) + 1
                    markWaitStarted(contributesToBatchMetrics = true)
                    if (!failIfStalled(submission.reason, submission)) {
                        logger("[ezw_ble][$channel][android] backpressure endpoint=$endpoint status=${submission.status} pending=$queueDepth")
                        scheduleWatchdog()
                    }
                    return
                }

                BleOtaWriteSubmission.Disposition.REJECTED -> {
                    pending.removeFirst()
                    logger("[ezw_ble][$channel][android] rejected endpoint=$endpoint reason=${submission.reason} pending=$queueDepth")
                    completeItem(
                        head,
                        BleOtaWriteError.unavailable(
                            endpoint = endpoint,
                            reason = submission.reason,
                            pending = queueDepth,
                            status = submission.status,
                            channel = channel,
                        ),
                    )
                }
            }
        }
        clearWait()
    }

    /** 同步 BUSY 与 callback 丢失共用 4 秒上限，避免 Dart await 永久挂起。 */
    private fun failIfStalled(
        reason: String,
        submission: BleOtaWriteSubmission?,
    ): Boolean {
        markWaitStarted()
        val startedAt = waitStartedAtMillis ?: return false
        val waitedMillis = nowMillis() - startedAt
        if (waitedMillis < STALL_TIMEOUT_MILLIS) {
            return false
        }

        if (channel == BleWriteChannel.FILE && inFlight?.batch?.fileBatchToken != null) {
            // A timeout does not release Android's physical slot any more than explicit cancel.
            cancelledInFlightCallbackPending = true
        }
        val snapshot = buildList {
            inFlight?.let(::add)
            addAll(pending)
        }
        inFlight = null
        pending.clear()
        clearWait()
        logger("[ezw_ble][$channel][android] stalled endpoint=$endpoint reason=$reason wait=${waitedMillis}ms pending=${snapshot.size}")
        completeSnapshot(
            snapshot,
            BleOtaWriteError.stalled(
                endpoint = endpoint,
                reason = reason,
                waitSeconds = waitedMillis / 1_000.0,
                pending = snapshot.size,
                status = submission?.status,
                channel = channel,
            ),
        )
        return true
    }

    /** 单包走自己的 completion；批次只结算一次，失败时丢掉同批剩余 pending。 */
    private fun completeItem(item: Item, error: BleOtaWriteError?) {
        val batch = item.batch
        if (batch == null) {
            item.completion(error)
            return
        }
        if (error != null) {
            pending.removeAll { it.batch === batch }
            batch.fileBatchToken?.let(::retireFilePacketBatch)
            batch.settle(error)
            return
        }
        batch.remaining -= 1
        if (batch.remaining <= 0) {
            logFileOnly { "[ezw_ble][$channel][android] batch completed endpoint=$endpoint pending=$queueDepth" }
            batch.fileBatchToken?.let(::retireFilePacketBatch)
            batch.settle(null)
        }
    }

    /** 取消/停滞快照里同一批次只能回调一次，避免重复完成 Dart Future。 */
    private fun completeSnapshot(snapshot: List<Item>, error: BleOtaWriteError) {
        // Retire all old identities before any callback can reserve a replacement.
        snapshot.forEach { it.batch?.fileBatchToken?.let(::retireFilePacketBatch) }
        val settledBatches = mutableSetOf<OtaWriteBatch>()
        snapshot.forEach { item ->
            val batch = item.batch
            if (batch == null) {
                item.completion(error)
            } else if (settledBatches.add(batch)) {
                batch.settle(error)
            }
        }
    }

    private fun retireFilePacketBatch(token: String) {
        if (fileBatchToken == token) {
            fileBatchToken = null
            fileBatchSubmitted = false
        }
    }

    private fun markWaitStarted(contributesToBatchMetrics: Boolean = false) {
        if (waitStartedAtMillis == null) {
            waitStartedAtMillis = nowMillis()
            waitContributesToBatchMetrics = contributesToBatchMetrics
        } else if (contributesToBatchMetrics) {
            waitContributesToBatchMetrics = true
        }
    }

    private fun scheduleWatchdog() {
        if (watchdog != null || queueDepth == 0) {
            return
        }
        val generation = ++watchdogGeneration
        watchdog = scheduler.schedule(RETRY_INTERVAL_MILLIS) {
            synchronized(stateLock) {
                if (generation != watchdogGeneration) {
                    return@synchronized
                }
                watchdog = null
                if (queueDepth > 0) {
                    pump()
                }
            }
        }
    }

    private fun clearWait() {
        val startedAt = waitStartedAtMillis
        if (startedAt != null && waitContributesToBatchMetrics) {
            val waitedMillis = (nowMillis() - startedAt).coerceAtLeast(0L)
            inFlight?.batch?.backpressureWaitMillis =
                (inFlight?.batch?.backpressureWaitMillis ?: 0L) + waitedMillis
            pending.firstOrNull()?.batch?.backpressureWaitMillis =
                (pending.firstOrNull()?.batch?.backpressureWaitMillis ?: 0L) + waitedMillis
        }
        waitStartedAtMillis = null
        waitContributesToBatchMetrics = false
        lastBackpressure = null
        watchdogGeneration += 1L
        watchdog?.cancel()
        watchdog = null
    }

    /**
     * Keep 240 batch completion/metrics and 233 lazy Debug packet diagnostics together.
     * Ordinary OTA does not format successful packets; FILE diagnostics stay independent.
     */
    private inline fun logFileOnly(message: () -> String) {
        if (channel != BleWriteChannel.OTA || BleOtaDebugLogPolicy.enabled) {
            logger(message())
        }
    }

    private companion object {
        const val RETRY_INTERVAL_MILLIS = 50L
        const val STALL_TIMEOUT_MILLIS = 4_000L
    }
}
