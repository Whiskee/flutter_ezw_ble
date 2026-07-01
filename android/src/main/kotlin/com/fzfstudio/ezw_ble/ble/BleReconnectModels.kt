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
 * Dart 从绑定缓存补种的 native 自动回连目标。
 *
 * 它只表达“用户仍允许该端点长期回连”，不代表当前已经存在 live GATT。
 */
internal data class BleReconnectSeed(
    /** Dart BleConfig name used to resolve current native config. */
    val belongConfig: String,
    /** Android BluetoothDevice address or plugin UUID surrogate. */
    val uuid: String,
    /** Last known Bluetooth name for diagnostics and fallback matching. */
    val name: String,
    /** Business serial number for multi-endpoint diagnosis. */
    val sn: String,
    /** Cached RSSI, only used for constructing the lightweight BleDevice. */
    val rssi: Int,
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
