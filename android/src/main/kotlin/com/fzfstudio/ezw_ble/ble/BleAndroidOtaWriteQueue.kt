package com.fzfstudio.ezw_ble.ble

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

/**
 * 单 endpoint Android OTA 写队列。
 *
 * Android 的 no-response 写仍然是单槽位 GATT 操作：同步 `SUCCESS` 只表示系统接受提交，
 * 真正释放下一包必须等 `onCharacteristicWrite`。同步 BUSY 是可恢复背压，原包保留到活动
 * 写回调或 watchdog 重试；其它错误、断连与超时均 fail closed，保证 Dart await 必有终态。
 */
internal class BleAndroidOtaWriteQueue(
    private val endpoint: String,
    private val submit: (ByteArray) -> BleOtaWriteSubmission,
    private val scheduler: BleOtaWriteScheduler,
    private val nowMillis: () -> Long,
    private val logger: (String) -> Unit = {},
) {
    private data class Item(
        val data: ByteArray,
        val completion: (BleOtaWriteError?) -> Unit,
    )

    private val pending = ArrayDeque<Item>()
    private var inFlight: Item? = null
    private var waitStartedAtMillis: Long? = null
    private var watchdog: BleOtaWriteCancellable? = null
    private var lastBackpressure: BleOtaWriteSubmission? = null

    /** 包含已提交但尚未收到 GATT callback 的包，便于错误详情反映真实深度。 */
    val queueDepth: Int
        @Synchronized get() = pending.size + if (inFlight == null) 0 else 1

    /** 入队后立即尝试提交；成功回调只会在本包自己的 characteristic callback 后触发。 */
    @Synchronized
    fun enqueue(data: ByteArray, completion: (BleOtaWriteError?) -> Unit) {
        pending.addLast(Item(data.copyOf(), completion))
        logger("[ezw_ble][ota][android] enqueued endpoint=$endpoint bytes=${data.size} pending=$queueDepth")
        pump()
    }

    /**
     * 接收当前 GATT session 的写完成回调。
     *
     * [ownsInFlight] 由 manager 根据普通发送队列当前 head 与 characteristic psType 判定；
     * false 的回调只表示此前占用 GATT 的其它写已释放，可用于唤醒同步 BUSY 的 OTA 包。
     */
    @Synchronized
    fun onCharacteristicWriteComplete(
        ownsInFlight: Boolean,
        success: Boolean,
        status: Int,
        statusName: String,
    ) {
        if (ownsInFlight) {
            val completed = inFlight
            if (completed != null) {
                inFlight = null
                clearWait()
                if (success) {
                    logger("[ezw_ble][ota][android] completed endpoint=$endpoint status=$statusName pending=$queueDepth")
                    completed.completion(null)
                } else {
                    logger("[ezw_ble][ota][android] failed endpoint=$endpoint status=$statusName pending=$queueDepth")
                    completed.completion(
                        BleOtaWriteError.unavailable(
                            endpoint = endpoint,
                            reason = "onCharacteristicWrite failed: $statusName",
                            pending = queueDepth,
                            status = status,
                            statusName = statusName,
                        ),
                    )
                }
            }
        } else if (inFlight == null && pending.isNotEmpty()) {
            // 前一笔普通/旧 OTA 写回调证明 GATT 单槽位已经释放，从头开始计算本包等待窗口。
            clearWait()
        }
        pump()
    }

    /** 断连、退出升级或 manager teardown 时释放所有 MethodChannel Future。 */
    @Synchronized
    fun cancelAll(reason: String) {
        val snapshot = buildList {
            inFlight?.let(::add)
            addAll(pending)
        }
        if (snapshot.isEmpty()) {
            clearWait()
            return
        }
        inFlight = null
        pending.clear()
        clearWait()
        logger("[ezw_ble][ota][android] cancelled endpoint=$endpoint reason=$reason pending=${snapshot.size}")
        snapshot.forEach { item ->
            item.completion(
                BleOtaWriteError.cancelled(
                    endpoint = endpoint,
                    reason = reason,
                    pending = snapshot.size,
                ),
            )
        }
    }

    /** 驱动同步提交；任何时刻最多只有一包处于已提交、等 callback 状态。 */
    private fun pump() {
        if (inFlight != null) {
            if (!failIfStalled("onCharacteristicWrite timeout", lastBackpressure)) {
                scheduleWatchdog()
            }
            return
        }

        while (pending.isNotEmpty()) {
            val head = pending.first()
            val submission = submit(head.data)
            when (submission.disposition) {
                BleOtaWriteSubmission.Disposition.ACCEPTED -> {
                    pending.removeFirst()
                    clearWait()
                    inFlight = head
                    waitStartedAtMillis = nowMillis()
                    lastBackpressure = null
                    logger("[ezw_ble][ota][android] submitted endpoint=$endpoint bytes=${head.data.size} pending=$queueDepth")
                    scheduleWatchdog()
                    return
                }

                BleOtaWriteSubmission.Disposition.BUSY -> {
                    lastBackpressure = submission
                    markWaitStarted()
                    if (!failIfStalled(submission.reason, submission)) {
                        logger("[ezw_ble][ota][android] backpressure endpoint=$endpoint status=${submission.status} pending=$queueDepth")
                        scheduleWatchdog()
                    }
                    return
                }

                BleOtaWriteSubmission.Disposition.REJECTED -> {
                    pending.removeFirst()
                    logger("[ezw_ble][ota][android] rejected endpoint=$endpoint reason=${submission.reason} pending=$queueDepth")
                    head.completion(
                        BleOtaWriteError.unavailable(
                            endpoint = endpoint,
                            reason = submission.reason,
                            pending = queueDepth,
                            status = submission.status,
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

        val snapshot = buildList {
            inFlight?.let(::add)
            addAll(pending)
        }
        inFlight = null
        pending.clear()
        clearWait()
        logger("[ezw_ble][ota][android] stalled endpoint=$endpoint reason=$reason wait=${waitedMillis}ms pending=${snapshot.size}")
        snapshot.forEach { item ->
            item.completion(
                BleOtaWriteError.stalled(
                    endpoint = endpoint,
                    reason = reason,
                    waitSeconds = waitedMillis / 1_000.0,
                    pending = snapshot.size,
                    status = submission?.status,
                ),
            )
        }
        return true
    }

    private fun markWaitStarted() {
        if (waitStartedAtMillis == null) {
            waitStartedAtMillis = nowMillis()
        }
    }

    private fun scheduleWatchdog() {
        if (watchdog != null || queueDepth == 0) {
            return
        }
        watchdog = scheduler.schedule(RETRY_INTERVAL_MILLIS) {
            synchronized(this) {
                watchdog = null
                if (queueDepth > 0) {
                    pump()
                }
            }
        }
    }

    private fun clearWait() {
        waitStartedAtMillis = null
        lastBackpressure = null
        watchdog?.cancel()
        watchdog = null
    }

    private companion object {
        const val RETRY_INTERVAL_MILLIS = 50L
        const val STALL_TIMEOUT_MILLIS = 4_000L
    }
}
