package com.fzfstudio.ezw_ble.ble

/** Exact Dart business-auth token derived from one connectStatus event. */
data class BleBusinessConnectionAttempt(
    val uuid: String,
    val sessionGeneration: Long,
    val attemptGeneration: Long,
)

/** MethodChannel status shared by prepare/commit business connection APIs. */
enum class BleBusinessConnectionStatus(val flutterValue: String) {
    ACCEPTED("accepted"),
    INVALID_ARGUMENTS("invalidArguments"),
    MISSING_ADMISSION("missingAdmission"),
    ATTEMPT_MISMATCH("attemptMismatch"),
    MISSING_PREPARE("missingPrepare"),
    DEVICE_DISCONNECTED("deviceDisconnected"),
    GATT_NOT_READY("gattNotReady"),
}

/** In-memory lease proving Dart is completing the current exact GATT attempt. */
internal data class BleBusinessConnectionLease(
    val attempt: BleBusinessConnectionAttempt,
    val preparedAtMillis: Long,
)

/**
 * Thread-safe exact-token lease registry shared by production code and native
 * tests. Endpoint replacement is intentional; removal is exact when initiated
 * by an asynchronous business attempt.
 */
internal class BleBusinessConnectionLeaseRegistry {
    private val leases = mutableMapOf<String, BleBusinessConnectionLease>()

    @Synchronized
    fun prepare(endpointKey: String, attempt: BleBusinessConnectionAttempt, nowMillis: Long) {
        leases[endpointKey] = BleBusinessConnectionLease(attempt, nowMillis)
    }

    @Synchronized
    fun attempt(endpointKey: String): BleBusinessConnectionAttempt? =
        leases[endpointKey]?.attempt

    @Synchronized
    fun abort(endpointKey: String, attempt: BleBusinessConnectionAttempt): Boolean {
        if (!matches(leases[endpointKey]?.attempt, attempt)) {
            return false
        }
        leases.remove(endpointKey)
        return true
    }

    @Synchronized
    fun remove(endpointKey: String) {
        leases.remove(endpointKey)
    }

    @Synchronized
    fun clear() {
        leases.clear()
    }

    private fun matches(
        current: BleBusinessConnectionAttempt?,
        expected: BleBusinessConnectionAttempt,
    ): Boolean = current != null &&
        current.uuid.equals(expected.uuid, ignoreCase = true) &&
        current.sessionGeneration == expected.sessionGeneration &&
        current.attemptGeneration == expected.attemptGeneration
}

/** Pure commit decision used by BleManager and executable native tests. */
internal object BleBusinessConnectionCommitPolicy {
    fun evaluate(
        attempt: BleBusinessConnectionAttempt?,
        admissionAttempt: BleBusinessConnectionAttempt?,
        preparedAttempt: BleBusinessConnectionAttempt?,
        requirePrepare: Boolean,
        hasGattSession: Boolean,
        hasDevice: Boolean,
        isSameGatt: Boolean,
        isSystemConnected: Boolean,
        isGattReady: Boolean,
    ): BleBusinessConnectionStatus {
        if (attempt == null ||
            attempt.uuid.isBlank() ||
            attempt.sessionGeneration <= 0L ||
            attempt.attemptGeneration <= 0L
        ) {
            return BleBusinessConnectionStatus.INVALID_ARGUMENTS
        }
        if (admissionAttempt == null || !hasGattSession) {
            return BleBusinessConnectionStatus.MISSING_ADMISSION
        }
        if (!admissionAttempt.uuid.equals(attempt.uuid, ignoreCase = true) ||
            admissionAttempt.sessionGeneration != attempt.sessionGeneration ||
            admissionAttempt.attemptGeneration != attempt.attemptGeneration
        ) {
            return BleBusinessConnectionStatus.ATTEMPT_MISMATCH
        }
        if (requirePrepare &&
            (preparedAttempt == null ||
                !preparedAttempt.uuid.equals(attempt.uuid, ignoreCase = true) ||
                preparedAttempt.sessionGeneration != attempt.sessionGeneration ||
                preparedAttempt.attemptGeneration != attempt.attemptGeneration)
        ) {
            return BleBusinessConnectionStatus.MISSING_PREPARE
        }
        if (!hasDevice || !isSameGatt || !isSystemConnected) {
            return BleBusinessConnectionStatus.DEVICE_DISCONNECTED
        }
        if (!isGattReady) {
            return BleBusinessConnectionStatus.GATT_NOT_READY
        }
        return BleBusinessConnectionStatus.ACCEPTED
    }
}
