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
        // 1、空身份直接忽略，避免污染 latestGenerations。
        if (endpointId.isBlank()) {
            return
        }
        // 2、只接受不低于当前高水位的新代次。
        val key = endpointKey(endpointId)
        val current = latestGenerations[key]
        if (current != null && generation < current) {
            return
        }
        // 3、登记新代次，并移除同 endpoint 的旧排队节点。
        latestGenerations[key] = generation
        manualQueue.removeAll { endpointKey(it.endpointId) == key && it.generation < generation }
        automaticQueue.removeAll { endpointKey(it.endpointId) == key && it.generation < generation }
    }

    /** 按真实物理 callback 到达顺序提交；首个节点立即成为 owner，其余进入优先队列。 */
    @Synchronized
    fun onPhysicalConnected(admission: BleConnectionAdmission): BleConnectionAdmissionDecision {
        // 1、按 suspended、generation、重复 session 依次做 fail-closed 校验。
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
        // 2、没有 active owner 时立即授权；否则按 source 进入 manual/automatic 队列。
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
        // 1、只有 exact active token 能释放 owner，迟到终态不得推进队列。
        val owner = active ?: return null
        if (!owner.matches(endpointId, generation, sessionId)) {
            return null
        }
        // 2、释放当前 owner，并只 grant 下一位等待节点。
        active = null
        return grantNext()
    }

    /**
     * 手动点击只提升同一 pending session，不创建重复 GATT，也不抢占当前 owner。
     */
    @Synchronized
    fun promote(endpointId: String, generation: Long, sessionId: Long) {
        // 1、查找同一代次的自动等待节点；当前 active 不被抢占。
        val index = automaticQueue.indexOfFirst { it.matches(endpointId, generation, sessionId) }
        if (index < 0) {
            return
        }
        // 2、移出自动队列后切换 source，保证手动优先级只影响后续 Gate 调度。
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
        // 1、规范化 endpoint 集合；空集合不改变任何 Gate 状态。
        val keys = endpointIds
            .asSequence()
            .filter { it.isNotBlank() }
            .map(::endpointKey)
            .toSet()
        if (keys.isEmpty()) {
            return null
        }
        // 2、先推进每个 endpoint 的 generation，阻断所有迟到 callback。
        keys.forEach { key ->
            latestGenerations[key] = nextGeneration(latestGenerations[key] ?: 0L)
        }
        // 3、原子移除两类等待队列，避免逐个取消期间短暂 grant。
        manualQueue.removeAll { endpointKey(it.endpointId) in keys }
        automaticQueue.removeAll { endpointKey(it.endpointId) in keys }
        if (active?.let { endpointKey(it.endpointId) in keys } != true) {
            return null
        }
        // 4、active 被取消时才授权下一 owner。
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
        // 1、标记 suspended，再统一失效 owner、队列和 generation 高水位。
        suspended = true
        invalidateAllLocked()
    }

    /**
     * clean cache / config 撤权会失效全部 active、waiting 与尚未物理回调的 attempt，
     * 但不会把 Gate 留在蓝牙关闭的 suspended 状态，后续显式新连接仍可正常注册。
     */
    @Synchronized
    fun invalidateAllAndReset() {
        // 1、配置重置同样失效所有 token，但保持 Gate 可接受新的显式连接。
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
