package com.fzfstudio.ezw_ble.ble

/**
 * Android Native 升级态写入的单一决策表。
 *
 * `sendCmd` 和 `sendCmdNoWait` 必须复用同一规则，避免一个入口默认拒绝而另一个入口
 * 静默绕过升级保护。no-wait 调用不接受业务白名单，因此调用时保持默认 false。
 */
internal object BleUpgradeCommandPolicy {
    /** OTA 通道或显式白名单可穿过升级态，其余写入只在非升级态允许。 */
    fun canSend(
        isUpgrading: Boolean,
        psType: Int,
        allowDuringUpgrade: Boolean = false,
    ): Boolean = !isUpgrading || psType == 1 || allowDuringUpgrade
}
