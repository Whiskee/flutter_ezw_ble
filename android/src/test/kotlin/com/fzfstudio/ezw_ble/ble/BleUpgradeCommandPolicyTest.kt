package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BleUpgradeCommandPolicyTest {
    @Test
    fun `non-upgrading endpoint allows every channel`() {
        assertTrue(BleUpgradeCommandPolicy.canSend(isUpgrading = false, psType = 0))
        assertTrue(BleUpgradeCommandPolicy.canSend(isUpgrading = false, psType = 1))
    }

    @Test
    fun `upgrading endpoint only allows ota or explicit control whitelist`() {
        assertFalse(BleUpgradeCommandPolicy.canSend(isUpgrading = true, psType = 0))
        assertTrue(BleUpgradeCommandPolicy.canSend(isUpgrading = true, psType = 1))
        assertTrue(
            BleUpgradeCommandPolicy.canSend(
                isUpgrading = true,
                psType = 0,
                allowDuringUpgrade = true,
            ),
        )
    }

    @Test
    fun `no-wait caller cannot whitelist a non-ota write`() {
        assertFalse(
            BleUpgradeCommandPolicy.canSend(
                isUpgrading = true,
                psType = 2,
                allowDuringUpgrade = false,
            ),
        )
    }
}
