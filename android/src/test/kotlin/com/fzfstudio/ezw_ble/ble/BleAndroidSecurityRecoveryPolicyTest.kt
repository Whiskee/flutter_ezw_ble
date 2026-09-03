package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BleAndroidSecurityRecoveryPolicyTest {
    @Test
    fun `only documented GATT and HCI security statuses are classified`() {
        listOf(5, 8, 12, 15).forEach {
            assertTrue(BleAndroidSecurityFailureClassifier.isGattSecurityFailure(it))
        }
        listOf(0, 6, 9, 13, 133).forEach {
            assertFalse(BleAndroidSecurityFailureClassifier.isGattSecurityFailure(it))
        }
        assertTrue(BleAndroidSecurityFailureClassifier.isHciSecurityFailure(5))
        assertTrue(BleAndroidSecurityFailureClassifier.isHciSecurityFailure(6))
        assertFalse(BleAndroidSecurityFailureClassifier.isHciSecurityFailure(8))
    }

    @Test
    fun `automatic episode retries four times and exhausts exactly on fifth`() {
        var count = 0
        var lastAttempt = 0L
        for (attempt in 1L..5L) {
            val (action, nextCount) = BleAndroidSecurityRecoveryPolicy.record(
                source = BleConnectSource.AUTO_RECONNECT,
                attemptGeneration = attempt,
                currentCount = count,
                lastCountedAttemptGeneration = lastAttempt,
            )
            assertEquals(
                if (attempt < 5L) BleAndroidSecurityRecoveryAction.RETRY
                else BleAndroidSecurityRecoveryAction.EXHAUSTED,
                action,
            )
            count = nextCount
            lastAttempt = attempt
        }
        assertEquals(5, count)

        val duplicate = BleAndroidSecurityRecoveryPolicy.record(
            BleConnectSource.AUTO_RECONNECT,
            attemptGeneration = 5L,
            currentCount = count,
            lastCountedAttemptGeneration = lastAttempt,
        )
        assertEquals(BleAndroidSecurityRecoveryAction.DUPLICATE_IGNORED, duplicate.first)
        assertEquals(5, duplicate.second)
    }

    @Test
    fun `manual failure bypasses automatic budget`() {
        val result = BleAndroidSecurityRecoveryPolicy.record(
            BleConnectSource.MANUAL_RECONNECT,
            attemptGeneration = 1L,
            currentCount = 4,
            lastCountedAttemptGeneration = 0L,
        )
        assertEquals(BleAndroidSecurityRecoveryAction.MANUAL_FAILURE, result.first)
        assertEquals(4, result.second)
    }

    @Test
    fun `bond removal fast rebuild is limited to pre physical owner`() {
        assertEquals(
            BleBondRemovalAction.FAST_REBUILD_PRE_PHYSICAL,
            BleBondRemovalPolicy.resolve(true, true, true, false, false),
        )
        assertEquals(
            BleBondRemovalAction.COUNT_SECURITY_FAILURE,
            BleBondRemovalPolicy.resolve(true, true, false, true, false),
        )
        assertEquals(
            BleBondRemovalAction.IGNORE,
            BleBondRemovalPolicy.resolve(true, true, true, false, true),
        )
    }
}
