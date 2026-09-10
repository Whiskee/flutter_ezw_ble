package com.fzfstudio.ezw_ble.ble

import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Process-local native trace for one real physical BLE attempt. */
internal class BleNativeConnectionTraceBuffer(
    val attemptId: String = UUID.randomUUID().toString(),
    private val startedAtMs: Long = SystemClock.elapsedRealtime(),
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val monotonicClock: () -> Long = SystemClock::elapsedRealtime,
    private val startedAtEpochMs: Long = wallClock(),
) {
    private val steps = mutableListOf<BleNativeConnectionTraceStep>()
    private val seen = mutableSetOf<String>()
    private var nextStepSeq = 1
    private var droppedCount = 0
    private var lastRssiDbm: Int? = null
    private var lastRssiAtMs: Long? = null
    private var phy: String? = null
    private var requestedPriority: String? = null
    private var rssiBucket: String? = null
    private var rssiStatus = "not_requested"

    /** Mark only existing sampling outcomes; telemetry never schedules a read. */
    @Synchronized
    fun markRssiRequested() { if (lastRssiDbm == null) rssiStatus = "not_observable" }

    @Synchronized
    fun markRssiFailed() { rssiStatus = if (lastRssiDbm == null) "read_failed" else "available" }

    @Synchronized
    fun record(
        stage: String,
        result: String,
        serviceType: String? = null,
        causeDomain: String? = null,
        causeCode: Int? = null,
        bondState: String? = null,
        writeLimitBytes: Int? = null,
        physicalConnectionEvent: String? = null,
    ) {
        val duplicateKey = "$stage|$result|${serviceType.orEmpty()}|${bondState.orEmpty()}|${writeLimitBytes ?: ""}"
        if (!seen.add(duplicateKey)) {
            return
        }
        val elapsed = (monotonicClock() - startedAtMs).coerceAtLeast(0L)
        append(
            BleNativeConnectionTraceStep(
                stepSeq = nextStepSeq++,
                stage = stage,
                result = result,
                elapsedMs = elapsed,
                occurredAtMs = startedAtEpochMs + elapsed,
                timingStatus = if (kotlin.math.abs(wallClock() - startedAtEpochMs - elapsed) > 1000) "clock_changed" else "valid",
                physicalConnectionEvent = physicalConnectionEvent,
                serviceType = serviceType,
                causeDomain = causeDomain,
                causeCode = causeCode,
                bondState = bondState,
                writeLimitBytes = writeLimitBytes,
            )
        )
    }

    @Synchronized
    fun updateRssi(rssi: Int) {
        rssiStatus = "available"
        lastRssiDbm = rssi
        lastRssiAtMs = monotonicClock()
        val nextBucket = when {
            rssi >= AndroidBleAdaptiveLinkPolicy.PROMOTE_TO_2M_RSSI_DBM -> "strong"
            rssi <= AndroidBleAdaptiveLinkPolicy.FALLBACK_TO_1M_RSSI_DBM -> "weak"
            else -> "mid"
        }
        if (rssiBucket != nextBucket) {
            rssiBucket = nextBucket
            recordLinkPolicy(trigger = "rssi_bucket_changed", rssiBucket = nextBucket)
        }
    }

    @Synchronized
    fun updatePhy(label: String?) {
        if (phy != label && label != null) {
            recordLinkPolicy(trigger = "phy_updated", phy = label, actionResult = "applied")
        }
        phy = label
    }

    @Synchronized
    fun updateRequestedPriority(priority: String?, accepted: Boolean) {
        if (requestedPriority != priority && priority != null) {
            recordLinkPolicy(
                trigger = "priority_requested",
                priorityAction = priority,
                actionResult = if (accepted) "accepted" else "rejected",
            )
        }
        requestedPriority = priority
    }

    /** Record a PHY policy decision separately from the controller's eventual callback. */
    @Synchronized
    fun recordPhyPolicy(trigger: String, requestedPhy: String, actionResult: String) {
        recordLinkPolicy(
            trigger = trigger,
            phy = requestedPhy,
            actionResult = actionResult,
        )
    }

    /** Record only policy transitions; high-frequency RSSI samples stay in the snapshot. */
    @Synchronized
    private fun recordLinkPolicy(
        trigger: String,
        rssiBucket: String? = null,
        phy: String? = null,
        priorityAction: String? = null,
        actionResult: String? = null,
    ) {
        val elapsed = (monotonicClock() - startedAtMs).coerceAtLeast(0L)
        append(
            BleNativeConnectionTraceStep(
                stepSeq = nextStepSeq++,
                stage = "link_policy",
                result = "state_changed",
                elapsedMs = elapsed,
                occurredAtMs = startedAtEpochMs + elapsed,
                timingStatus = if (kotlin.math.abs(wallClock() - startedAtEpochMs - elapsed) > 1000) "clock_changed" else "valid",
                linkTrigger = trigger,
                rssiBucket = rssiBucket,
                phy = phy,
                priorityAction = priorityAction,
                actionResult = actionResult,
            )
        )
    }

    @Synchronized
    fun snapshot(): JSONObject = JSONObject()
        .put("attemptId", attemptId)
        .put("rssiStatus", rssiStatus)
        .put("capturedElapsedMs", (monotonicClock() - startedAtMs).coerceAtLeast(0L))
        .put("steps", JSONArray().also { array ->
            // Preserve the process-local producer sequence across bounded-buffer
            // replacement so Dart can distinguish newly retained terminal steps.
            steps.forEach { step -> array.put(step.toJson()) }
        })
        .also { json ->
            lastRssiDbm?.let { json.put("lastRssiDbm", it) }
            lastRssiAtMs?.let { json.put("rssiAgeMs", monotonicClock() - it) }
            phy?.let { json.put("phy", it) }
            requestedPriority?.let { json.put("requestedPriority", it) }
        }

    private fun append(step: BleNativeConnectionTraceStep) {
        if (steps.size < MAX_STEPS) {
            steps.add(step)
            return
        }
        // Keep the start, physical callbacks and earliest failure while evicting
        // verbose intermediate details. Gap count covers actual lost rows only.
        steps.removeAll { it.result == "gap" }
        while (steps.size > MAX_STEPS - 2) {
            val firstFailure = steps.indexOfFirst { it.result in setOf("failed", "timeout", "abnormal") }
            val candidate = steps.indices.firstOrNull { index ->
                index != 0 && index != firstFailure &&
                    steps[index].physicalConnectionEvent == null &&
                    steps[index].stage !in setOf("disconnect", "gatt_ready")
            } ?: 1
            steps.removeAt(candidate)
            droppedCount += 1
        }
        steps.add(BleNativeConnectionTraceStep(
            stepSeq = step.stepSeq,
            stage = "trace", result = "gap", elapsedMs = step.elapsedMs,
            occurredAtMs = step.occurredAtMs, timingStatus = step.timingStatus,
            droppedCount = droppedCount,
        ))
        steps.add(step.copy(stepSeq = nextStepSeq++))
    }

    private data class BleNativeConnectionTraceStep(
        val stepSeq: Int,
        val stage: String,
        val result: String,
        val elapsedMs: Long,
        val occurredAtMs: Long? = null,
        val timingStatus: String? = null,
        val physicalConnectionEvent: String? = null,
        val serviceType: String? = null,
        val causeDomain: String? = null,
        val causeCode: Int? = null,
        val droppedCount: Int? = null,
        val bondState: String? = null,
        val writeLimitBytes: Int? = null,
        val linkTrigger: String? = null,
        val rssiBucket: String? = null,
        val phy: String? = null,
        val priorityAction: String? = null,
        val actionResult: String? = null,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("stepSeq", stepSeq)
            .put("stage", stage)
            .put("result", result)
            .put("elapsedMs", elapsedMs)
            .also { json ->
                occurredAtMs?.let { json.put("occurredAtMs", it) }
                timingStatus?.let { json.put("timingStatus", it) }
                physicalConnectionEvent?.let { json.put("physicalConnectionEvent", it) }
                serviceType?.let { json.put("serviceType", it) }
                causeDomain?.let { json.put("causeDomain", it) }
                causeCode?.let { json.put("causeCode", it) }
                droppedCount?.let { json.put("droppedCount", it) }
                bondState?.let { json.put("bondState", it) }
                writeLimitBytes?.let { json.put("writeLimitBytes", it) }
                linkTrigger?.let { json.put("linkTrigger", it) }
                rssiBucket?.let { json.put("rssiBucket", it) }
                phy?.let { json.put("phy", it) }
                priorityAction?.let { json.put("priorityAction", it) }
                actionResult?.let { json.put("actionResult", it) }
            }
    }

    companion object {
        const val MAX_STEPS = 32
    }
}
