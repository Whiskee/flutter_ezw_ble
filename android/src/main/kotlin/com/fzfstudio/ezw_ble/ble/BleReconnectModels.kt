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
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource

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
    var timer: BleReconnectScheduleHandle? = null,
    /** 当前 timer 是否由 pre-physical deadline 产生；目标可见只允许接管这种 timer。 */
    var pendingPassiveRetry: Boolean = false,
    /** 重建 timer 的代际；被取消的旧 timer 即使迟到执行也不能启动新 GATT。 */
    var retryScheduleGeneration: Long = 0L,
    /** 连续未收到物理连接 callback 的 deadline 次数，用于长离线自适应退避。 */
    var consecutivePrePhysicalTimeouts: Int = 0,
    /**
     * 单轮自动回连 GATT 在收到真实物理连接回调前的 deadline。
     *
     * 它回收 Android 长时间无回调的 passive 或“目标可见直连” GATT；一旦进入
     * admission Gate（包含 queued），就必须被取消，不能把 Gate 等待误判为连接失败。
     */
    var pendingPhysicalDeadline: BleReconnectScheduleHandle? = null,
    /**
     * 当前 pre-physical GATT。常态为 passive `autoConnect=true`，扫描命中后可短暂
     * 保存一次 `autoConnect=false` 的直连句柄，二者都必须按 exact identity 回收。
     */
    var passiveGatt: BluetoothGatt? = null,
    /** 当前 GATT 是否来自一次扫描可见后的真实直连。 */
    var pendingVisibleDirectConnect: Boolean = false,
    /** 当前目标是否等待获得全局可见性直连槽位。 */
    var visibleDirectConnectRequested: Boolean = false,
    /** 启动当前 GATT 的单调时间，仅用于输出物理回调等待诊断。 */
    var passiveStartedAtMs: Long = 0L,
    /** Bluetooth adapter is off; keep task but pause attempts until powered on. */
    var pausedByBluetoothOff: Boolean = false,
    /** 当前 pending session 的来源；手动点击可提升但不会新建重复 GATT。 */
    var source: BleConnectSource = BleConnectSource.AUTO_RECONNECT,
)

/** Android passive GATT 长离线退避策略；不改变 `connectGatt(autoConnect=true)` 的 owner。 */
internal object BlePassiveReconnectDelayPolicy {
    /** 目标重新可见后的短防抖，避免扫描 burst 触发连续 register/unregister。 */
    const val VISIBLE_WAKE_DEBOUNCE_MS = 250L

    /** 仅连续 pre-physical deadline 失败参与分档，其他失败不推进该计数。 */
    fun delayAfterConsecutivePrePhysicalTimeouts(timeoutCount: Int): Long = when {
        timeoutCount <= 3 -> 1500L
        timeoutCount <= 10 -> 5000L
        else -> 30000L
    }
}

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

/** Native 激活结果；Android 只有稳定 address owner，不存在 identityPending。 */
internal enum class BleReconnectActivationState(val flutterValue: String) {
    RESOLVED("resolved"),
    REJECTED("rejected"),
}

/** MethodChannel 单目标回执，防止 Dart 把被过滤的空 address 误判成长期 owner。 */
internal data class BleReconnectActivationResult(
    val target: BleReconnectSeed,
    val state: BleReconnectActivationState,
    val reason: String,
) {
    fun toFlutterMap(): Map<String, String> = mapOf(
        "belongConfig" to target.belongConfig,
        "uuid" to target.uuid,
        "name" to target.name,
        "state" to state.flutterValue,
        "reason" to reason,
    )
}

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
