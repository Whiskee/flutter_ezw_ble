/*
 * BleConnectRequest.kt
 * flutter_ezw_ble
 *
 * Keeps foreground connect request identity and logging in one place. This
 * helper does not decide routing; it makes connect/request logs stable across
 * active connect and reconnect recovery paths.
 */

package com.fzfstudio.ezw_ble.ble

/**
 * One foreground connection request as received from Dart.
 *
 * The manager keeps this value small so stale callbacks can be explained by
 * uuid/name/sn/config without pulling scan or GATT state into the request model.
 */
internal data class BleConnectRequest(
    /** Dart BleConfig name used to resolve scan and private service rules. */
    val belongConfig: String,
    /** Android BluetoothDevice address or plugin UUID surrogate. */
    val uuid: String,
    /** Device name requested by Dart or parsed from scan result. */
    val name: String,
    /** Business serial number used by upper-layer multi-leg aggregation. */
    val sn: String,
    /** OTA recovery flag kept in logs for upgrade reconnect diagnosis. */
    val afterUpgrade: Boolean,
    /** Direct connect skips scan-first routing when the caller already owns identity. */
    val directConnect: Boolean,
    /** Waiting-device requests should not be mistaken for a foreground noDeviceFound. */
    val isWaitingDevice: Boolean,
) {
    /**
     * Builds the fixed connect/request log line.
     *
     * The field order is intentionally stable so terminal filters and QA scripts
     * can compare active connect and auto reconnect traces.
     */
    fun logMessage(resolvedName: String?, cachedDevices: Int, scanCache: Int): String =
        // Keep this single-line: Android logcat and Flutter EventChannel logs are easier to grep.
        "connect/request uuid=$uuid name=$name sn=$sn config=$belongConfig " +
            "resolvedName=$resolvedName directConnect=$directConnect " +
            "afterUpgrade=$afterUpgrade isWaitingDevice=$isWaitingDevice " +
            "connectedDevices=$cachedDevices scanCache=$scanCache"
}
