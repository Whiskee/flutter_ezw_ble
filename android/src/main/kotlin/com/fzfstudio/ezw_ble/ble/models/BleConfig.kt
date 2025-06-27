package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable

data class BleConfig(
    //  属性配置名称
    val name: String,
    //  蓝牙搜索
    val scan: BleScan,
    //  配置多个私有服务
    val privateServices: List<BlePrivateService>,
    //  是否主动发起设备绑定
    val initiateBinding: Boolean,
    //  毫秒
    val connectTimeout: Double,
    //  设备升级后启动新固件之前需要的时间，用于重连时
    val upgradeSwapTime: Double,
    //  设置MTU
    val mtu: Int,
): GsonSerializable() {

    companion object {
        fun empty(): BleConfig = BleConfig("", BleScan.empty(), listOf(), true, 15000.0, 60000.0, 247)
    }

    /**
     *  不能为空对象：配置名称，ServiceUUID
     */
    fun isEmpty(): Boolean = name.isEmpty() || privateServices.isEmpty()

}