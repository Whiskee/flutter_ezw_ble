package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable

/// 蓝牙搜索
data class BleScan(
    //  设备名称过滤条件
    val nameFilters: List<String>,
    //  设备SN解析规则
    val snRule: BleSnRule,
): GsonSerializable() {

    companion object {
        fun empty() = BleScan(listOf(), BleSnRule.empty())
    }

}