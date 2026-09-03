package com.fzfstudio.ezw_ble.ble

import java.util.UUID

/**
 * Android 5403 Gate 的 exact owner。
 *
 * [gattIdentity] 使用对象身份而不是设备地址；同地址的新 BluetoothGatt 不能消费旧写回调。
 */
internal data class BleAndroidSecurityGateOwner(
    val endpointId: String,
    val sessionGeneration: Long,
    val attemptGeneration: Long,
    val sessionId: Long,
    val gattIdentity: Any,
)

internal data class BleAndroidSecurityGateAttempt(
    val owner: BleAndroidSecurityGateOwner,
    val characteristicUuid: UUID,
)

/** 单进程 Gate registry；所有入口都要求 exact owner、GATT identity 和 characteristic。 */
internal class BleAndroidSecurityGateAttemptRegistry {
    private val inFlight = mutableMapOf<String, BleAndroidSecurityGateAttempt>()
    private val passed = mutableMapOf<String, BleAndroidSecurityGateOwner>()

    @Synchronized
    fun start(owner: BleAndroidSecurityGateOwner, characteristicUuid: UUID): Boolean {
        val key = key(owner.endpointId)
        if (inFlight.containsKey(key) || exact(passed[key], owner)) {
            return false
        }
        inFlight[key] = BleAndroidSecurityGateAttempt(owner, characteristicUuid)
        return true
    }

    @Synchronized
    fun consume(
        owner: BleAndroidSecurityGateOwner,
        characteristicUuid: UUID,
    ): BleAndroidSecurityGateAttempt? {
        val key = key(owner.endpointId)
        val attempt = inFlight[key] ?: return null
        if (!exact(attempt.owner, owner) || attempt.characteristicUuid != characteristicUuid) {
            return null
        }
        inFlight.remove(key)
        return attempt
    }

    @Synchronized
    fun consumeInFlight(owner: BleAndroidSecurityGateOwner): BleAndroidSecurityGateAttempt? {
        val key = key(owner.endpointId)
        val attempt = inFlight[key] ?: return null
        if (!exact(attempt.owner, owner)) {
            return null
        }
        inFlight.remove(key)
        return attempt
    }

    @Synchronized
    fun markPassed(owner: BleAndroidSecurityGateOwner) {
        passed[key(owner.endpointId)] = owner
    }

    @Synchronized
    fun isInFlight(owner: BleAndroidSecurityGateOwner): Boolean =
        exact(inFlight[key(owner.endpointId)]?.owner, owner)

    @Synchronized
    fun hasPassed(owner: BleAndroidSecurityGateOwner): Boolean =
        exact(passed[key(owner.endpointId)], owner)

    @Synchronized
    fun cancel(owner: BleAndroidSecurityGateOwner) {
        val key = key(owner.endpointId)
        if (exact(inFlight[key]?.owner, owner)) {
            inFlight.remove(key)
        }
        if (exact(passed[key], owner)) {
            passed.remove(key)
        }
    }

    @Synchronized
    fun cancelEndpoint(endpointId: String) {
        val key = key(endpointId)
        inFlight.remove(key)
        passed.remove(key)
    }

    /** Adapter/reset teardown 后没有任何 callback 仍可拥有 Gate。 */
    @Synchronized
    fun clear() {
        inFlight.clear()
        passed.clear()
    }

    private fun exact(
        current: BleAndroidSecurityGateOwner?,
        expected: BleAndroidSecurityGateOwner,
    ): Boolean = current != null &&
        current.endpointId.equals(expected.endpointId, ignoreCase = true) &&
        current.sessionGeneration == expected.sessionGeneration &&
        current.attemptGeneration == expected.attemptGeneration &&
        current.sessionId == expected.sessionId &&
        current.gattIdentity === expected.gattIdentity

    private fun key(endpointId: String): String = endpointId.lowercase()
}
