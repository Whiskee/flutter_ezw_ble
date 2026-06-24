package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.EZW_BLE_CHANNEL_NAME
import com.fzfstudio.ezw_utils.extension.toCamelCase
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * 当前已注册的 EventChannel sink 缓存。
 *
 * Flutter 的 EventChannel 会按事件类型分别注册监听，这里用完整 channel name 做 key，
 * 避免不同事件流之间互相覆盖。
 */
private val bleEvents: MutableMap<String, EventChannel.EventSink> = mutableMapOf()

/**
 * Android EventChannel 枚举。
 *
 * 每个枚举值对应一个独立的 Flutter 事件流；事件发送方通过 `event` 取当前 sink，
 * 注册流程通过 `registerEventChannel` 在插件启动时完成。
 */
enum class BleEC {
    //  蓝牙状态
    //  - unknown = 0
    //  - resetting = 1
    //  - unsupported = 2
    //  - unauthorized = 3
    //  - poweredOff = 4
    //  - poweredOn = 5
    //  - noLocation = 6
    BLE_STATE,
    //  扫描结果
    SCAN_RESULT,
    //  连接状态
    CONNECT_STATUS,
    //  接收数据
    RECEIVE_DATA,
    //  日志
    LOGGER;

    //  自定义事件名称
    private val eventLabel: String
        get() = "${EZW_BLE_CHANNEL_NAME}_${name.toCamelCase()}"

    //  获取事件
    val event: EventChannel.EventSink?
        get() = bleEvents[eventLabel]

    /**
     * 注册当前事件类型对应的 EventChannel。
     *
     * Flutter 端重新监听时会覆盖旧 sink；取消监听时会移除缓存，避免原生继续向无效 sink 发事件。
     */
    fun registerEventChannel(binaryMessenger: BinaryMessenger) {
        EventChannel(binaryMessenger, eventLabel).setStreamHandler(
            object : EventChannel.StreamHandler {
                /**
                 * Flutter 端开始监听该事件流。
                 *
                 * 这里只缓存 sink，不主动发送历史事件；历史状态由各业务入口按需查询。
                 */
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    events?.let { sink -> bleEvents[eventLabel] = sink  }
                }

                /**
                 * Flutter 端取消监听该事件流。
                 *
                 * 移除 sink 可以避免后台 isolate 销毁后继续写事件导致 platform channel 异常。
                 */
                override fun onCancel(arguments: Any?) {
                    bleEvents.remove(eventLabel)
                }
            }
        )
    }

}
