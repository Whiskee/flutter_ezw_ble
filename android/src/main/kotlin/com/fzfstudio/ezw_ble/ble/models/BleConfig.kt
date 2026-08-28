package com.fzfstudio.ezw_ble.ble.models

import com.fzfstudio.ezw_utils.gson.GsonSerializable

/**
 * Flutter 下发到 Android 原生层的 BLE 配置。
 *
 * 配置决定扫描匹配、私有服务发现、连接超时、MTU 和原生自动回连策略。Android 侧不能在运行中
 * 推断这些字段，必须以 Dart `BleConfig.customToJson` 结果为准。
 */
data class BleConfig(
    /** 配置名称，用于 connectDevice 的 belongConfig 路由。 */
    val name: String,
    /** 扫描匹配规则。 */
    val scan: BleScan,
    /** GATT 初始化需要发现并注册 notify 的私有服务列表。 */
    val privateServices: List<BlePrivateService>,
    /** 可选的受保护写门禁；存在时必须在普通 Notify/CCCD 之前完成。 */
    val securityGate: BleSecurityGate? = null,
    /** 是否由原生主动发起系统 bonding。 */
    val initiateBinding: Boolean,
    /** 前台连接/GATT readiness 超时时间，单位毫秒。 */
    val connectTimeout: Double,
    /** OTA 后设备重启到新固件可连接前的额外等待时间，单位毫秒。 */
    val upgradeSwapTime: Double,
    /** 连接后请求的 BLE MTU。 */
    val mtu: Int,
    /** 是否启用原生自动回连。只有 Dart 确认业务 connected 后才会生效。 */
    val autoReconnect: Boolean = false,
    /** 自动回连退避计数兼容字段；当前实现不把次数作为停止条件。 */
    val autoReconnectMaxAttempts: Int = 0,
    /** 是否允许平台 passive autoConnect 能力。 */
    val autoReconnectUseNativePassive: Boolean = true,
    /** Android 高可靠链路模式；只由明确需要高吞吐且易受遮挡的设备配置开启。 */
    val androidHighReliabilityMode: Boolean = false,
): GsonSerializable() {

    companion object {
        /**
         * 构造空配置。
         *
         * 空配置只用于占位/默认值，不应该参与真实扫描或连接。
         */
        fun empty(): BleConfig = BleConfig(
            name = "",
            scan = BleScan.empty(),
            privateServices = listOf(),
            initiateBinding = true,
            connectTimeout = 15000.0,
            upgradeSwapTime = 60000.0,
            mtu = 247,
        )
    }

    /**
     * 判断配置是否缺失最小可用字段。
     *
     * name 负责路由，privateServices 负责 GATT readiness；二者任一缺失都无法完成真实连接。
     */
    fun isEmpty(): Boolean {
        // 1. 没有 name 时 connectDevice 无法匹配 belongConfig。
        if (name.isEmpty()) {
            return true
        }

        // 2. 没有私有服务时即便物理链路连接成功，也无法完成业务可用的 GATT 初始化。
        return privateServices.isEmpty()
    }

}
