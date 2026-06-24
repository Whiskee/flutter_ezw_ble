/*
 * BleReconnectModels.kt
 * flutter_ezw_ble
 *
 * Contains Android auto reconnect state models and delay policy. These models
 * describe native physical-link recovery only; every reconnect still has to
 * rediscover GATT services, characteristics, and notify/CCCD state.
 */

package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothGatt
import java.util.Timer

/**
 * Runtime auto reconnect task for one Android BLE device.
 *
 * The task is armed only after Dart confirms business connected. This prevents
 * native reconnect from reviving devices that reached GATT ready but failed app auth.
 */
internal data class BleReconnectTask(
    /** Dart BleConfig name used when rebuilding a connect request. */
    val belongConfig: String,
    /** Android BluetoothDevice address or plugin UUID surrogate. */
    val uuid: String,
    /** Latest visible Bluetooth name, retained for scan/cache matching. */
    var name: String,
    /** Business serial number, retained for upper-layer pairing/multi-device diagnosis. */
    val sn: String,
    /** Number of reconnect attempts already consumed; diagnostic/backoff only, never a stop condition. */
    var attempt: Int = 0,
    /** Backoff timer for active reconnect mode. */
    var timer: Timer? = null,
    /** Passive autoConnect GATT kept so zombie sessions can be explicitly closed. */
    var passiveGatt: BluetoothGatt? = null,
    /** Bluetooth adapter is off; keep task but pause attempts until powered on. */
    var pausedByBluetoothOff: Boolean = false,
)

/**
 * Persisted reconnect identity.
 *
 * Only identity/config data is persisted because BluetoothGatt and service
 * objects are process-local and invalid after app death or adapter reset.
 */
internal data class BlePersistedReconnectTarget(
    /** Dart BleConfig name used to restore scan and GATT rules. */
    val belongConfig: String,
    /** Android BluetoothDevice address or plugin UUID surrogate. */
    val uuid: String,
    /** Last known device name for fallback matching. */
    val name: String,
    /** Business serial number for upper-layer diagnostics. */
    val sn: String,
)

/**
 * Exponential backoff policy for Android active reconnect.
 *
 * Passive autoConnect still needs watchdog/backoff because Android GATT can get
 * stuck without a useful callback; this policy keeps retry cadence bounded
 * without ever cancelling the long-lived reconnect intent by itself.
 */
internal object BleAutoReconnectDelayPolicy {
    /**
     * Calculates bounded reconnect delay in milliseconds.
     *
     * Negative config values are coerced to safe lower bounds so malformed JSON
     * cannot create immediate busy loops or negative timer delays.
     */
    fun calculate(baseMs: Int, maxMs: Int, attempt: Int): Long {
        val base = baseMs.coerceAtLeast(0).toLong()
        val max = maxMs.coerceAtLeast(baseMs).toLong()
        if (attempt <= 1) {
            return base.coerceAtMost(max)
        }
        var delay = base
        // Cap doubling count to avoid overflow while still giving enough spread for repeated failures.
        repeat((attempt - 1).coerceAtMost(12)) {
            delay = (delay * 2).coerceAtMost(max)
        }
        return delay.coerceAtMost(max)
    }
}
