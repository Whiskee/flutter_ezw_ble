package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject

/**
 * Test-branch Android adapter for the pure timing ledger. It owns only diagnostic resources:
 * public getter sampling and a second receiver; neither can call Manager or a GATT operation.
 * Enabling the existing Debug policy allocates nothing until an exact Bond wait actually starts.
 */
internal object BleBondTimingDiagnostics {
    private const val TAG = "BleBondTiming"
    private val lock = Any()
    @Volatile private var enabled = false
    @Volatile private var runtime: Runtime? = null

    /** No Manager access: turning off only retires already-created diagnostic resources. */
    fun setEnabled(value: Boolean) {
        synchronized(lock) {
            if (!value) runtime?.probe?.stopAll("debug_disabled")
            enabled = value
        }
    }

    /** Called at receiver entry, before parsing extras or waiting for any BLE monitor. */
    fun capture(): BleBondTimingStamp? {
        if (!enabled) return null
        val active = runtime ?: return null
        return BleBondTimingProbe.inheritReceiverTokens(active.probe.capture(freeze()))
    }

    /** Exact owner validation belongs to the caller; this method cannot grant an admission. */
    fun start(context: Context, owner: BleBondTimingOwner, device: BluetoothDevice) {
        if (!enabled) return
        runCatching {
            synchronized(lock) {
                if (!enabled) return
                val active = runtime ?: Runtime(context.applicationContext ?: context).also { runtime = it }
                active.probe.start(owner) { device.bondState }
                active.registerObserver()
            }
        }.onFailure { error ->
            // Even bootstrap failures remain diagnostics and cannot fail createBond/readiness.
            if (enabled) runCatching {
                val stamp = freeze()
                Log.w(TAG, JSONObject(mapOf(
                    "stage" to "probe_start_error", "probeId" to "failed-${stamp.monoNs}",
                    "endpoint" to owner.endpoint, "config" to owner.config,
                    "sessionGeneration" to owner.sessionGeneration,
                    "attemptGeneration" to owner.attemptGeneration, "sessionId" to owner.sessionId,
                    "monoNs" to stamp.monoNs, "wallMs" to stamp.rawWallMs,
                    "rawWallMs" to stamp.rawWallMs, "anchorMonoNs" to stamp.monoNs,
                    "anchorWallMs" to stamp.rawWallMs, "thread" to stamp.thread,
                    "error" to BleBondTimingProbe.errorText(error),
                )).toString())
            }
        }
    }

    /** Suppress all work before constructing fields when Debug is off or no probe is active. */
    fun record(
        endpoint: String,
        stage: String,
        stamp: BleBondTimingStamp? = capture(),
        sessionId: Long? = null,
        fields: () -> Map<String, Any?> = { emptyMap() },
    ) {
        if (stamp == null) return
        runCatching { runtime?.probe?.record(endpoint, stage, stamp, sessionId, fields()) }
    }

    /** Receiver-only tail preserves independent delivery evidence without delaying GATT. */
    fun finishAfterDiscovery(endpoint: String, sessionId: Long) {
        runCatching { runtime?.probe?.finishAfterDiscovery(endpoint, sessionId) }
    }

    /** Cancelling a window never touches a production timer, Bond state, or GATT handle. */
    fun stop(endpoint: String, reason: String, sessionId: Long? = null) {
        runCatching { runtime?.probe?.stop(endpoint, reason, sessionId) }
    }

    fun stopAll(reason: String) {
        runCatching { runtime?.probe?.stopAll(reason) }
    }

    /** One shared wall/elapsed anchor per probe allows wall-clock adjustments to be detected. */
    private fun freeze(): BleBondTimingStamp = BleBondTimingStamp(
        SystemClock.elapsedRealtimeNanos(), System.currentTimeMillis(),
        "${Thread.currentThread().name}:${Thread.currentThread().id}",
    )

    /**
     * Sampling and receiver delivery use separate threads so a slow binder getter cannot make
     * the diagnostic receiver appear late. Both stop when the last exact observation ends.
     */
    private class Runtime(private val context: Context) {
        private val samplerThread = HandlerThread("BleBondTimingSample").apply { start() }
        private val receiverThread = HandlerThread("BleBondTimingReceiver").apply { start() }
        private val samplerHandler = Handler(samplerThread.looper)
        private val receiverHandler = Handler(receiverThread.looper)
        private var receiverRegistered = false
        // Keep one immutable diagnostic record solely to attribute an unregister failure.
        @Volatile private var lastRecord: Map<String, Any?>? = null
        val probe = BleBondTimingProbe(
            enabled = { enabled }, clock = ::freeze,
            schedule = { delay, action ->
                val task = Runnable { action() }
                check(samplerHandler.postDelayed(task, delay)) { "sampler looper rejected task" }
                BleBondTimingCancellation { samplerHandler.removeCallbacks(task) }
            },
            emit = { fields ->
                if (enabled) {
                    lastRecord = fields
                    Log.i(TAG, JSONObject(fields).toString())
                }
            },
            onIdle = { receiverHandler.post { retireIfIdle() } },
        )
        private val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                // Capture before parcelable/extra extraction; this receiver has no business callback.
                val stamp = capture() ?: return
                if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                runCatching {
                    val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                    }
                    device?.let {
                        probe.record(it.address, "receiver_background", stamp, fields = mapOf(
                            "bondState" to intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1),
                            "previousBondState" to intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1),
                        ))
                    }
                }.onFailure {
                    probe.recordAll("observer_receive_error", mapOf("error" to BleBondTimingProbe.errorText(it)))
                }
            }
        }

        /** Register independently, on a HandlerThread; the production receiver remains unchanged. */
        fun registerObserver() {
            receiverHandler.post {
                if (probe.isIdle() || !enabled || receiverRegistered) return@post
                runCatching {
                    val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        // Bluetooth broadcasts may originate from a privileged non-system UID.
                        context.registerReceiver(receiver, filter, null, receiverHandler, Context.RECEIVER_EXPORTED)
                    } else {
                        @Suppress("DEPRECATION")
                        context.registerReceiver(receiver, filter, null, receiverHandler)
                    }
                    receiverRegistered = true
                    probe.recordAll("observer_registered")
                }.onFailure {
                    probe.recordAll("observer_register_error", mapOf("error" to BleBondTimingProbe.errorText(it)))
                }
            }
        }

        /** Removal is serialized on the observer thread; a new runtime cannot reuse its receiver. */
        private fun retireIfIdle() {
            val retire = synchronized(lock) {
                if (runtime !== this || !probe.isIdle()) false else {
                    runtime = null
                    true
                }
            }
            if (!retire) return
            if (receiverRegistered) {
                runCatching { context.unregisterReceiver(receiver) }.onFailure { error ->
                    if (enabled) runCatching {
                        val fields = lastRecord?.toMutableMap() ?: return@runCatching
                        val stamp = freeze()
                        fields["stage"] = "observer_unregister_error"
                        fields["monoNs"] = stamp.monoNs
                        fields["rawWallMs"] = stamp.rawWallMs
                        fields["wallMs"] = (fields["anchorWallMs"] as Long) +
                            (stamp.monoNs - (fields["anchorMonoNs"] as Long)) / 1_000_000L
                        fields["thread"] = stamp.thread
                        fields["error"] = BleBondTimingProbe.errorText(error)
                        Log.w(TAG, JSONObject(fields).toString())
                    }
                }
                receiverRegistered = false
            }
            samplerHandler.removeCallbacksAndMessages(null)
            samplerThread.quitSafely()
            receiverThread.quitSafely()
        }
    }
}
