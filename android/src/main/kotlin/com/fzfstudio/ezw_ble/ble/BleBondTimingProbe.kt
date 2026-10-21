package com.fzfstudio.ezw_ble.ble

/** A timestamp is frozen at the producer; logcat delivery time is never an event clock. */
internal data class BleBondTimingStamp(
    val monoNs: Long,
    val rawWallMs: Long,
    val thread: String,
    /** Receiver entry freezes diagnostic tokens before decoding an endpoint from the intent. */
    val windowTokens: Map<String, String>? = null,
)

/** Immutable diagnostic identity; it never grants permission to advance a BLE owner. */
internal data class BleBondTimingOwner(
    val endpoint: String,
    val config: String,
    val sessionGeneration: Long,
    val attemptGeneration: Long,
    val sessionId: Long,
)

/** Diagnostic work can be cancelled independently of the production Bond/GATT timers. */
internal fun interface BleBondTimingCancellation { fun cancel() }

/**
 * Read-only, bounded Bond observation. The injectable scheduler executes the actual sampling
 * logic in JVM tests; Android supplies a separate background thread, never a BLE callback queue.
 * A public bondState getter may be framework-cached: a late observation cannot prove that the
 * Bluetooth service committed Bond late. No callback from this class may control a connection.
 */
internal class BleBondTimingProbe(
    private val enabled: () -> Boolean,
    private val clock: () -> BleBondTimingStamp,
    private val schedule: (Long, () -> Unit) -> BleBondTimingCancellation,
    private val emit: (Map<String, Any?>) -> Unit,
    private val onIdle: () -> Unit = {},
) {
    /** A new token per observation window makes escaped timers harmless after replacement. */
    private data class Window(
        val owner: BleBondTimingOwner,
        val probeId: String,
        val anchor: BleBondTimingStamp,
        val read: () -> Int,
        var lastState: Int? = null,
        var lastError: String? = null,
        var timer: BleBondTimingCancellation? = null,
        var tailTimer: BleBondTimingCancellation? = null,
        var sampling: Boolean = true,
    )
    private val lock = Any()
    private val windows = mutableMapOf<String, Window>()
    private var sequence = 0L

    /** Already-active exact owners are idempotent; a new attempt retires only its old endpoint. */
    fun start(owner: BleBondTimingOwner, read: () -> Int) {
        if (!enabled()) return
        val window: Window
        val replaced: Window?
        synchronized(lock) {
            if (!enabled()) return
            val key = owner.endpoint.lowercase()
            val previous = windows[key]
            if (previous?.owner == owner) return
            replaced = windows.remove(key)
            val anchor = clock()
            window = Window(owner, "${anchor.monoNs}-${++sequence}", anchor, read)
            windows[key] = window
        }
        replaced?.let { finishRemoved(it, "admission_replaced") }
        publish(window, "probe_start", window.anchor)
        arm(window, 0L)
    }

    /** A receiver cannot choose its endpoint until extras are decoded; freeze all active tokens. */
    fun capture(stamp: BleBondTimingStamp): BleBondTimingStamp = synchronized(lock) {
        stamp.copy(windowTokens = windows.mapValues { it.value.probeId })
    }

    /** Returns a frozen observation, filtered against an active endpoint or exact session. */
    fun record(
        endpoint: String,
        stage: String,
        stamp: BleBondTimingStamp = clock(),
        sessionId: Long? = null,
        fields: Map<String, Any?> = emptyMap(),
    ) {
        if (!enabled()) return
        val key = endpoint.lowercase()
        val window = synchronized(lock) { windows[key] } ?: return
        // Receiver-entry time and token both predate parsing/Manager work. An old callback must
        // not be re-attributed by an endpoint lookup after cancel + same-address replacement.
        if (stamp.monoNs < window.anchor.monoNs) return
        if (stamp.windowTokens != null && stamp.windowTokens[key] != window.probeId) return
        if (sessionId != null && window.owner.sessionId != sessionId) return
        publish(window, stage, stamp, fields)
    }

    /** Observer registration failures are evidence for every currently observed exact owner. */
    fun recordAll(stage: String, fields: Map<String, Any?> = emptyMap()) {
        if (!enabled()) return
        val stamp = clock()
        val snapshot = synchronized(lock) { windows.values.toList() }
        snapshot.forEach { publish(it, stage, stamp, fields) }
    }

    /**
     * Stop getter reads at discovery, but retain up to one second of receiver-only evidence.
     * The main receiver may submit discovery before the independent receiver gets CPU time;
     * closing immediately would turn that ordinary ordering into missing background evidence.
     */
    fun finishAfterDiscovery(endpoint: String, sessionId: Long) {
        val window = synchronized(lock) {
            val current = windows[endpoint.lowercase()] ?: return
            if (current.owner.sessionId != sessionId || !current.sampling) return
            current.sampling = false
            current
        }
        runCatching { window.timer?.cancel() }
        val remainingMs = (WINDOW_NS - (clock().monoNs - window.anchor.monoNs)) / 1_000_000L
        val tailMs = minOf(1_000L, remainingMs.coerceAtLeast(0L))
        publish(window, "probe_tail", clock(), mapOf("tailMs" to tailMs))
        val task = runCatching {
            schedule(tailMs) { stop(endpoint, "discovery_tail_complete", sessionId) }
        }.getOrElse {
            publish(window, "sampler_schedule_error", clock(), mapOf("error" to errorText(it)))
            stop(endpoint, "sampler_unavailable", sessionId)
            return
        }
        synchronized(lock) {
            if (windows[endpoint.lowercase()] === window && enabled()) window.tailTimer = task
            else task.cancel()
        }
    }

    /** Removal is diagnostic-only; neither the production timeout nor GATT is retained here. */
    fun stop(endpoint: String, reason: String, sessionId: Long? = null) {
        val window = synchronized(lock) {
            val key = endpoint.lowercase()
            val current = windows[key] ?: return
            if (sessionId != null && current.owner.sessionId != sessionId) return
            windows.remove(key)
        } ?: return
        finishRemoved(window, reason)
        notifyIdle()
    }

    /** Disable/reset/release invalidates tokens before cancelled tasks can run again. */
    fun stopAll(reason: String) {
        val snapshot = synchronized(lock) {
            windows.values.toList().also { windows.clear() }
        }
        snapshot.forEach { finishRemoved(it, reason) }
        notifyIdle()
    }

    fun isIdle(): Boolean = synchronized(lock) { windows.isEmpty() }

    /** The blocking framework read happens outside the ledger monitor and outside BLE locks. */
    private fun sample(window: Window) {
        if (!isSampling(window)) return
        val before = clock()
        if (!enabled()) {
            stop(window.owner.endpoint, "debug_disabled", window.owner.sessionId)
            return
        }
        if (before.monoNs - window.anchor.monoNs >= WINDOW_NS) {
            stop(window.owner.endpoint, "deadline", window.owner.sessionId)
            return
        }
        val result = runCatching(window.read)
        val after = clock()
        val fields = mutableMapOf<String, Any?>(
            "readStartedMonoNs" to before.monoNs,
            "readDurationNs" to (after.monoNs - before.monoNs),
            "getterMayBeCached" to true,
        )
        val stage = synchronized(lock) {
            if (windows[window.owner.endpoint.lowercase()] !== window || !window.sampling || !enabled()) return
            if (result.isFailure) {
                val error = errorText(result.exceptionOrNull())
                if (error == window.lastError) null else {
                    window.lastError = error
                    fields["error"] = error
                    "public_bond_read_error"
                }
            } else {
                val state = result.getOrThrow()
                val changed = state != window.lastState || window.lastError != null
                fields["bondState"] = state
                fields["previousBondState"] = window.lastState
                window.lastState = state
                window.lastError = null
                if (changed) "public_bond_state" else null
            }
        }
        if (stage != null) publish(window, stage, after, fields)
        if (!isSampling(window)) return
        val remainingNs = WINDOW_NS - (after.monoNs - window.anchor.monoNs)
        if (remainingNs <= 0L) {
            stop(window.owner.endpoint, "deadline", window.owner.sessionId)
        } else {
            arm(window, minOf(SAMPLE_MS, (remainingNs + 999_999L) / 1_000_000L))
        }
    }

    /** Scheduling races with teardown are resolved by token comparison, including escaped tasks. */
    private fun arm(window: Window, delayMs: Long) {
        if (!isSampling(window)) return
        val task = runCatching { schedule(delayMs) { sample(window) } }.getOrElse {
            publish(window, "sampler_schedule_error", clock(), mapOf("error" to errorText(it)))
            stop(window.owner.endpoint, "sampler_unavailable", window.owner.sessionId)
            return
        }
        synchronized(lock) {
            if (windows[window.owner.endpoint.lowercase()] === window && window.sampling && enabled()) {
                window.timer = task
            } else task.cancel()
        }
    }

    private fun isSampling(window: Window): Boolean = synchronized(lock) {
        windows[window.owner.endpoint.lowercase()] === window && window.sampling
    }

    private fun isCurrent(window: Window): Boolean = synchronized(lock) {
        windows[window.owner.endpoint.lowercase()] === window
    }

    /** Stop evidence preserves the original anchor even after the window has been removed. */
    private fun finishRemoved(window: Window, reason: String) {
        runCatching { window.timer?.cancel() }
        runCatching { window.tailTimer?.cancel() }
        publish(window, "probe_stop", clock(), mapOf("reason" to reason), allowRemoved = true)
    }

    /** Logger/observer failures must never escape into the production connection pipeline. */
    private fun notifyIdle() {
        if (isIdle()) runCatching(onIdle)
    }

    private fun publish(
        window: Window,
        stage: String,
        stamp: BleBondTimingStamp,
        fields: Map<String, Any?> = emptyMap(),
        allowRemoved: Boolean = false,
    ) {
        if (!enabled() || (!allowRemoved && !isCurrent(window))) return
        val data = linkedMapOf<String, Any?>(
            "stage" to stage, "probeId" to window.probeId,
            "endpoint" to window.owner.endpoint, "config" to window.owner.config,
            "sessionGeneration" to window.owner.sessionGeneration,
            "attemptGeneration" to window.owner.attemptGeneration,
            "sessionId" to window.owner.sessionId,
            "monoNs" to stamp.monoNs,
            "wallMs" to window.anchor.rawWallMs + (stamp.monoNs - window.anchor.monoNs) / 1_000_000L,
            "rawWallMs" to stamp.rawWallMs,
            "anchorMonoNs" to window.anchor.monoNs,
            "anchorWallMs" to window.anchor.rawWallMs,
            "thread" to stamp.thread,
        )
        data.putAll(fields)
        runCatching { emit(data) }
    }

    companion object {
        // Only synchronous diagnostic lineage is retained; production callbacks keep their signature.
        private val receiverEntry = ThreadLocal<BleBondTimingStamp?>()

        /** Preserve the original receiver token through Manager/monitor waits, then restore nesting. */
        fun <T> withReceiverStamp(stamp: BleBondTimingStamp?, action: () -> T): T {
            if (stamp == null) return action()
            val previous = receiverEntry.get()
            receiverEntry.set(stamp)
            try {
                return action()
            } finally {
                if (previous == null) receiverEntry.remove() else receiverEntry.set(previous)
            }
        }

        /** Each stage freezes its own time, while attribution stays with receiver-entry tokens. */
        fun inheritReceiverTokens(stamp: BleBondTimingStamp): BleBondTimingStamp {
            val entry = receiverEntry.get() ?: return stamp
            return stamp.copy(windowTokens = entry.windowTokens)
        }

        private const val SAMPLE_MS = 100L
        private const val WINDOW_NS = 15_000_000_000L
        /** Exception type/message are enough to identify permission/registration/getter failures. */
        fun errorText(error: Throwable?): String = "${error?.javaClass?.simpleName}:${error?.message}"
    }
}
