package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConfig
import kotlin.test.Test
import kotlin.test.assertEquals

/** initConfigs diff 的行为测试：只有授权删除/关闭才撤销 native owner。 */
class BleReconnectConfigDiffTest {
    @Test
    fun `removed and disabled auto reconnect configs are revoked atomically`() {
        val previous = listOf(
            config("removed", enabled = true),
            config("disabled", enabled = true),
            config("kept", enabled = true),
            config("never-enabled", enabled = false),
        )
        val current = listOf(
            config("disabled", enabled = false),
            config("kept", enabled = true),
        )

        assertEquals(
            setOf("removed", "disabled"),
            BleReconnectConfigDiff.revokedConfigNames(previous, current),
        )
    }

    private fun config(name: String, enabled: Boolean): BleConfig =
        BleConfig.empty().copy(name = name, autoReconnect = enabled)
}
