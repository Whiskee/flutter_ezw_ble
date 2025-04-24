package com.fzfstudio.ezw_ble.ble.models.enums

import com.google.gson.annotations.JsonAdapter

@JsonAdapter(BleConnectStateAdapter::class)
enum class BleConnectState {
    //  步骤1：执行连接
    CONNECTING,
    //  步骤2: 获取连接设备回复
    CONTACT_DEVICE,
    //  步骤3: 搜索设备服务特征
    SEARCH_SERVICE,
    //  步骤4: 获取服务读写特征
    SEARCH_CHARS,
    //  步骤5: 特征获取完毕，连接流程完成
    CONNECT_FINISH,
    //  错误码：
    //  主动断连
    DISCONNECT_BY_MYSELF,
    //  系统断连
    DISCONNECT_FROM_SYS,
    //  空的UUID
    EMPTY_UUID,
    //  设备没被发现
    NO_DEVICE_FOUND,
    //  已经被绑定
    ALREADY_BOUND,
    //  获取服务发现失败
    SERVICE_FAIL,
    //  获取读写特征失败
    CHARS_FAIL,
    //  连接超时
    TIMEOUT,
    //  已连接
    CONNECTED,
    //  升级状态
    UPGRADE,
    //  无状态
    NONE;

    /**
     *  是否正在连接中
     */
    val isConnecting: Boolean
        get() = this == CONNECTING ||
                this == CONTACT_DEVICE ||
                this == SEARCH_SERVICE ||
                this == SEARCH_CHARS ||
                this == CONNECT_FINISH
    /**
     *  已连接：真实连接和升级是属于连接状态
     */
    val isConnected: Boolean
        get() = this == CONNECTED || this == UPGRADE

    /**
     *  是否已经断连
     */
    val isDisconnected: Boolean
        get() = this == DISCONNECT_BY_MYSELF ||
                this == DISCONNECT_FROM_SYS

    /**
     *  是否错误请求
     */
    val isError: Boolean
        get() = this == EMPTY_UUID ||
                this == NO_DEVICE_FOUND ||
                this == ALREADY_BOUND ||
                this == SERVICE_FAIL ||
                this == CHARS_FAIL ||
                this == TIMEOUT
}