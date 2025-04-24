package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable

data class BleConfig(
    val name: String,
    //  可以配置多个uuid数据
    val uuids: List<BleUuid>,
    //  毫秒
    val connectTimeout: Double,
    //  设备升级后启动新固件之前需要的时间，用于重连时
    val upgradeSwapTime: Double,
    //  设置MTU
    val mtu: Int,
    //  如果设置了匹配规则，cd
    val  snRule: BleSnRule,
): GsonSerializable() {

    companion object {
        fun empty(): BleConfig = BleConfig("", listOf(), 15000.0, 60000.0, 255, BleSnRule.empty())
    }

    /**
     *  不能为空对象：配置名称，ServiceUUID
     */
    fun isEmpty(): Boolean = name.isEmpty() || uuids.isEmpty()

}