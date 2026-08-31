package com.fzfstudio.ezw_ble.ble

import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Process-local native trace for one real physical BLE attempt. */
internal class BleNativeConnectionTraceBuffer(
    val attemptId: String = UUID.randomUUID().toString(),
    private val startedAtMs: Long = SystemClock.elapsedRealtime(),
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

    @Synchronized
    fun record(
        stage: String,
        result: String,
        serviceType: String? = null,
        causeDomain: String? = null,
        causeCode: Int? = null,
        bondState: String? = null,
        writeLimitBytes: Int? = null,
    ) {
        val duplicateKey = "$stage|$result|${serviceType.orEmpty()}|${bondState.orEmpty()}|${writeLimitBytes ?: ""}"
        if (!seen.add(duplicateKey)) {
            return
        }
        append(
            BleNativeConnectionTraceStep(
                stepSeq = nextStepSeq++,
                stage = stage,
                result = result,
                elapsedMs = (SystemClock.elapsedRealtime() - startedAtMs).coerceAtLeast(0L),
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
        lastRssiDbm = rssi
        lastRssiAtMs = SystemClock.elapsedRealtime()
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
        append(
            BleNativeConnectionTraceStep(
                stepSeq = nextStepSeq++,
                stage = "link_policy",
                result = "state_changed",
                elapsedMs = (SystemClock.elapsedRealtime() - startedAtMs).coerceAtLeast(0L),
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
        .put("capturedElapsedMs", (SystemClock.elapsedRealtime() - startedAtMs).coerceAtLeast(0L))
        .put("steps", JSONArray().also { array ->
            // Preserve the process-local producer sequence across bounded-buffer
            // replacement so Dart can distinguish newly retained terminal steps.
            steps.forEach { step -> array.put(step.toJson()) }
        })
        .also { json ->
            lastRssiDbm?.let { json.put("lastRssiDbm", it) }
            lastRssiAtMs?.let { json.put("rssiAgeMs", SystemClock.elapsedRealtime() - it) }
            phy?.let { json.put("phy", it) }
            requestedPriority?.let { json.put("requestedPriority", it) }
        }

    private fun append(step: BleNativeConnectionTraceStep) {
        if (steps.size < MAX_STEPS) {
            steps.add(step)
            return
        }
        droppedCount += 1
        val terminal = step.isTerminal
        val gap = BleNativeConnectionTraceStep(
            // The incoming non-terminal stage is omitted by the bounded buffer,
            // so its sequence becomes the observable gap sequence.
            stepSeq = step.stepSeq,
            stage = "trace",
            result = "gap",
            elapsedMs = step.elapsedMs,
            droppedCount = droppedCount,
        )
        if (terminal) {
            steps[MAX_STEPS - 2] = gap
            // Keep the terminal after the gap in both array and producer order.
            steps[MAX_STEPS - 1] = step.copy(stepSeq = nextStepSeq++)
        } else {
            steps[MAX_STEPS - 1] = gap
        }
    }

    private data class BleNativeConnectionTraceStep(
        val stepSeq: Int,
        val stage: String,
        val result: String,
        val elapsedMs: Long,
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
        val isTerminal: Boolean
            get() = stage == "disconnect" ||
                result == "success" ||
                result == "failed" ||
                result == "timeout" ||
                result == "cancelled" ||
                result == "abnormal" ||
                result == "expected"

        fun toJson(): JSONObject = JSONObject()
            .put("stepSeq", stepSeq)
            .put("stage", stage)
            .put("result", result)
            .put("elapsedMs", elapsedMs)
            .also { json ->
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
