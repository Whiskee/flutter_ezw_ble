package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable

/// 蓝牙搜索
data class BleScan(
    //  设备名称过滤条件
    val nameFilters: List<String>,
    //  设备SN解析规则
    val snRule: BleSnRule?,
    //  组合设备数:总数，如果为1不执行匹配，返回单个设备，如果大于2则默认开启匹配模式
    val matchCount: Int,
): GsonSerializable() {

    companion object {
        fun empty() = BleScan(listOf(), BleSnRule.empty(), 1)
    }

}