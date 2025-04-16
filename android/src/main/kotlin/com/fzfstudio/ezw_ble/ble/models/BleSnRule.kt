package com.fzfstudio.ezw_ble.ble.models

import java.io.Serializable

data class BleSnRule(
    //  总长度识别，如果为0，则表示适配所有长度
    val byteLength: Int,
    //  开始截断位置
    val startSubIndex: Int,
    //  自定义正则修正字符
    val replaceRex: String,
    //  扫描设备时，只返回SN含有过滤标识的对象
    val scanFilterMarks: List<String>,
    //  组合设备数:总数，如果为1不执行匹配，返回单个设备，如果大于2则默认开启匹配模式
    val matchCount: Int,
): Serializable {
    companion object {
        fun empty() = BleSnRule(0, 0, "", listOf(), 1)
    }
}
