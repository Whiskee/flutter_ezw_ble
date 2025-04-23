package com.fzfstudio.ezw_ble.ble

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import com.fzfstudio.ezw_ble.EZW_BLE_CHANNEL_NAME
import com.fzfstudio.ezw_utils.extension.toCamelCase
import com.fzfstudio.ezw_utils.extension.toUpperSnakeCase
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_utils.gson.toJson
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

private val bleEvents: MutableMap<String, EventChannel.EventSink> = mutableMapOf()

enum class BleMC {
    //  当前平台
    GET_PLATFORM_VERSION,
    //  当前蓝牙状态
    BLE_STATE,
    //  开启蓝牙配置
    ENABLE_CONFIG,
    //  开始扫描设备
    START_SCAN,
    //  停止扫描设备
    STOP_SCAN,
    //  连接设备(uuid)
    CONNECT_DEVICE,
    //  断连设备(uuid)
    DISCONNECT_DEVICE,
    //  主动回复设备连接成功
    DEVICE_CONNECTED,
    //  发送指令
    SEND_CMD,
    //  进入升级模式
    ENTER_UPGRADE_STATE,
    //  退出升级模式
    QUITE_UPGRADE_STATE,
    //  打开蓝牙设置页面
    OPEN_BLE_SETTINGS,
    //  打开App设置页面
    OPEN_APP_SETTINGS,
    //  未知
    UNKNOWN;

    companion object {
        fun from(method: String): BleMC = valueOf(method.toUpperSnakeCase())
    }

    /**
     *  处理回调结果
     */
    fun handle(context: Context, arguments: Any?,  result: MethodChannel.Result) {
        when (this) {
            GET_PLATFORM_VERSION -> {
                return result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            BLE_STATE -> {
                return result.success(BleManager.instance.currentBleState)
            }
            ENABLE_CONFIG -> {
                val jsonMap = arguments as Map<*, *>?
                val config = jsonMap?.toJson<BleConfig>()
                if (config != null) {
                    BleManager.instance.enableConfig(config)
                }
            }
            START_SCAN -> BleManager.instance.startScan()
            STOP_SCAN -> BleManager.instance.stopScan()
            CONNECT_DEVICE -> {
                val jsonMap = arguments as Map<*, *>?
                val uuid = jsonMap?.get("uuid") as String? ?: ""
                val sn = jsonMap?.get("sn") as String? ?: ""
                val afterUpgrade = jsonMap?.get("afterUpgrade") as Boolean? ?: false
                if (uuid.isNotEmpty() && sn.isNotEmpty()) {
                    BleManager.instance.connect(uuid, sn, afterUpgrade = afterUpgrade)
                }
            }
            DISCONNECT_DEVICE -> {
                val uuid = arguments as String? ?: ""
                BleManager.instance.disconnect(uuid)
            }
            SEND_CMD -> {
                val jsonMap = arguments as Map<*, *>?
                val uuid = jsonMap?.get("uuid") as String? ?: ""
                val data = jsonMap?.get("data") as ByteArray? ?: byteArrayOf()
                val isOtaCmd = jsonMap?.get("isOtaCmd") as Boolean? == true
                BleManager.instance.sendCmd(uuid, data, isOtaCmd = isOtaCmd)
            }
            ENTER_UPGRADE_STATE -> {
                val uuid = arguments as String? ?: ""
                BleManager.instance.enterUpgradeState(uuid)
            }
            QUITE_UPGRADE_STATE -> {
                val uuid = arguments as String? ?: ""
                BleManager.instance.quiteUpgradeState(uuid)
            }
            DEVICE_CONNECTED -> {
                val uuid = arguments as String? ?: ""
                BleManager.instance.setConnected(uuid)
            }
            OPEN_BLE_SETTINGS -> {
                val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            }
            OPEN_APP_SETTINGS -> {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", context.packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            }
            else -> null
        }
        result.success(null)
    }
}

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
    RECEIVE_DATA;

    //  自定义事件名称
    private val eventLabel: String
        get() = "${EZW_BLE_CHANNEL_NAME}_${name.toCamelCase()}"

    //  获取事件
    val event: EventChannel.EventSink?
        get() = bleEvents[eventLabel]

    /**
     * 注册EventChannel
     */
    fun registerEventChannel(binaryMessenger: BinaryMessenger) {
        EventChannel(binaryMessenger, eventLabel).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    events?.let { sink -> bleEvents[eventLabel] = sink  }
                }
                override fun onCancel(arguments: Any?) {
                    bleEvents.remove(eventLabel)
                }
            }
        )
    }

}