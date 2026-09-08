package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Reconcile 必须在任何 owner 创建前拒绝撤销授权、OTA 和未知模式。 */
class BleReconnectActivationGuardPolicyTest {
    @Test
    fun `revoked and ota targets fail closed while authorized reconnect proceeds`() {
        assertEquals(
            "authorizationRevoked",
            BleReconnectActivationGuardPolicy.rejectionReason(
                BleReconnectActivationMode.RECONCILE,
                hasPersistedAuthorization = false,
                isUpgradeDevice = false,
            ),
        )
        assertEquals(
            "otaInProgress",
            BleReconnectActivationGuardPolicy.rejectionReason(
                BleReconnectActivationMode.RECONCILE,
                hasPersistedAuthorization = true,
                isUpgradeDevice = true,
            ),
        )
        assertEquals(
            "invalidMode",
            BleReconnectActivationGuardPolicy.rejectionReason(
                BleReconnectActivationMode.UNKNOWN,
                hasPersistedAuthorization = true,
                isUpgradeDevice = false,
            ),
        )
        assertNull(
            BleReconnectActivationGuardPolicy.rejectionReason(
                BleReconnectActivationMode.RECONCILE,
                hasPersistedAuthorization = true,
                isUpgradeDevice = false,
            ),
        )
    }
}
