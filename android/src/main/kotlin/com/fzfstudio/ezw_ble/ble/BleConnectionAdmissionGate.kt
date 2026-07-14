package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource

/** 一次真实物理连接回调等待进入全局 GATT pipeline 的身份。 */
internal data class BleConnectionAdmission(
    val endpointId: String,
    val generation: Long,
    val sessionId: Long,
    val source: BleConnectSource,
)

/** 物理连接回调提交给 Gate 后的同步判定。 */
internal enum class BleConnectionAdmissionDecision {
    GRANTED,
    QUEUED,
    STALE,
    SUSPENDED,
    DUPLICATE,
    INVALID_IDENTITY,
}

/**
 * Android 全局 BLE 连接准入 Gate 的纯状态机。
 *
 * Gate 只决定谁可以运行 service/characteristic/CCCD/业务鉴权 pipeline，不持有
 * BluetoothGatt。automatic 节点按物理 callback FIFO；manual 节点只提升等待队列，
 * 绝不抢占 active owner。generation + sessionId 同时防止迟到 callback 复活旧连接。
 */
internal class BleConnectionAdmissionGate {
    private val latestGenerations = mutableMapOf<String, Long>()
    private val manualQueue = mutableListOf<BleConnectionAdmission>()
    private val automaticQueue = mutableListOf<BleConnectionAdmission>()
    private var active: BleConnectionAdmission? = null
    private var suspended = false

    /** 注册当前 endpoint 的最新尝试代次，并移除尚未执行的旧排队节点。 */
    @Synchronized
    fun registerAttempt(endpointId: String, generation: Long) {
        if (endpointId.isBlank()) {
            return
        }
        val key = endpointKey(endpointId)
        val current = latestGenerations[key]
        if (current != null && generation < current) {
            return
        }
        latestGenerations[key] = generation
        manualQueue.removeAll { endpointKey(it.endpointId) == key && it.generation < generation }
        automaticQueue.removeAll { endpointKey(it.endpointId) == key && it.generation < generation }
    }

    /** 按真实物理 callback 到达顺序提交；首个节点立即成为 owner，其余进入优先队列。 */
    @Synchronized
    fun onPhysicalConnected(admission: BleConnectionAdmission): BleConnectionAdmissionDecision {
        if (admission.endpointId.isBlank()) {
            return BleConnectionAdmissionDecision.INVALID_IDENTITY
        }
        if (suspended) {
            return BleConnectionAdmissionDecision.SUSPENDED
        }
        val latest = latestGenerations[endpointKey(admission.endpointId)]
        if (latest == null || latest != admission.generation) {
            return BleConnectionAdmissionDecision.STALE
        }
        if (active?.sameSession(admission) == true ||
            manualQueue.any { it.sameSession(admission) } ||
            automaticQueue.any { it.sameSession(admission) }
        ) {
            return BleConnectionAdmissionDecision.DUPLICATE
        }
        if (active == null) {
            active = admission
            return BleConnectionAdmissionDecision.GRANTED
        }
        if (admission.source == BleConnectSource.MANUAL_RECONNECT) {
            manualQueue.add(admission)
        } else {
            automaticQueue.add(admission)
        }
        return BleConnectionAdmissionDecision.QUEUED
    }

    /** 仅 exact active session 可以完成；返回随后获得准入的节点。 */
    @Synchronized
    fun complete(endpointId: String, generation: Long, sessionId: Long): BleConnectionAdmission? {
        val owner = active ?: return null
        if (!owner.matches(endpointId, generation, sessionId)) {
            return null
        }
        active = null
        return grantNext()
    }

    /**
     * 手动点击只提升同一 pending session，不创建重复 GATT，也不抢占当前 owner。
     */
    @Synchronized
    fun promote(endpointId: String, generation: Long, sessionId: Long) {
        val index = automaticQueue.indexOfFirst { it.matches(endpointId, generation, sessionId) }
        if (index < 0) {
            return
        }
        val promoted = automaticQueue.removeAt(index).copy(source = BleConnectSource.MANUAL_RECONNECT)
        manualQueue.add(promoted)
    }

    /** 真取消 endpoint 的 active/queued owner；active 被移除时返回下一位 owner。 */
    @Synchronized
    fun cancelEndpoint(endpointId: String): BleConnectionAdmission? {
        return cancelEndpoints(setOf(endpointId))
    }

    /**
     * 原子撤销一组 endpoint，避免逐个 cancel 时把同批待撤销节点短暂 grant 并启动 pipeline。
     * 返回值只可能是未被撤销的下一 owner，调用方完成旧 GATT teardown 后再启动它。
     */
    @Synchronized
    fun cancelEndpoints(endpointIds: Set<String>): BleConnectionAdmission? {
        val keys = endpointIds
            .asSequence()
            .filter { it.isNotBlank() }
            .map(::endpointKey)
            .toSet()
        if (keys.isEmpty()) {
            return null
        }
        keys.forEach { key ->
            latestGenerations[key] = nextGeneration(latestGenerations[key] ?: 0L)
        }
        manualQueue.removeAll { endpointKey(it.endpointId) in keys }
        automaticQueue.removeAll { endpointKey(it.endpointId) in keys }
        if (active?.let { endpointKey(it.endpointId) in keys } != true) {
            return null
        }
        active = null
        return grantNext()
    }

    /**
     * 只取消 exact session，不失效同 endpoint 的更新 generation。
     *
     * manager 在 GATT context 丢失时用这个入口防止 Gate active 悬挂；迟到旧 callback
     * 不能借此取消已经注册的新 attempt。
     */
    @Synchronized
    fun cancelSession(endpointId: String, generation: Long, sessionId: Long): BleConnectionAdmission? {
        if (endpointId.isBlank()) {
            return null
        }
        manualQueue.removeAll { it.matches(endpointId, generation, sessionId) }
        automaticQueue.removeAll { it.matches(endpointId, generation, sessionId) }
        if (active?.matches(endpointId, generation, sessionId) != true) {
            return null
        }
        active = null
        return grantNext()
    }

    /** 蓝牙关闭会原子失效所有 owner/queue；旧 callback 在恢复后也不能再次准入。 */
    @Synchronized
    fun suspendAndReset() {
        suspended = true
        invalidateAllLocked()
    }

    /**
     * clean cache / config 撤权会失效全部 active、waiting 与尚未物理回调的 attempt，
     * 但不会把 Gate 留在蓝牙关闭的 suspended 状态，后续显式新连接仍可正常注册。
     */
    @Synchronized
    fun invalidateAllAndReset() {
        invalidateAllLocked()
        suspended = false
    }

    /** 蓝牙恢复只解除暂停；每个 endpoint 仍需注册一个新 generation。 */
    @Synchronized
    fun resume() {
        suspended = false
    }

    /** 调用方已持有对象锁；统一递增 generation 并清空所有 owner。 */
    private fun invalidateAllLocked() {
        latestGenerations.replaceAll { _, generation ->
            nextGeneration(generation)
        }
        active = null
        manualQueue.clear()
        automaticQueue.clear()
    }

    private fun grantNext(): BleConnectionAdmission? {
        val next = when {
            manualQueue.isNotEmpty() -> manualQueue.removeAt(0)
            automaticQueue.isNotEmpty() -> automaticQueue.removeAt(0)
            else -> null
        }
        active = next
        return next
    }

    private fun BleConnectionAdmission.sameSession(other: BleConnectionAdmission): Boolean =
        matches(other.endpointId, other.generation, other.sessionId)

    private fun BleConnectionAdmission.matches(endpointId: String, generation: Long, sessionId: Long): Boolean =
        this.endpointId.equals(endpointId, ignoreCase = true) &&
            this.generation == generation &&
            this.sessionId == sessionId

    private fun endpointKey(endpointId: String): String = endpointId.trim().lowercase()

    private fun nextGeneration(generation: Long): Long =
        if (generation == Long.MAX_VALUE) Long.MAX_VALUE else generation + 1L
}
