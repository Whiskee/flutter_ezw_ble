package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConfig

/** initConfigs 更新时计算被撤销 native 回连授权的配置。 */
internal object BleReconnectConfigDiff {
    fun revokedConfigNames(
        previous: List<BleConfig>,
        current: List<BleConfig>,
    ): Set<String> {
        val currentByName = current.associateBy { it.name }
        return previous
            .asSequence()
            .filter { it.autoReconnect }
            .filter { old -> currentByName[old.name]?.autoReconnect != true }
            .map { it.name }
            .toSet()
    }
}
