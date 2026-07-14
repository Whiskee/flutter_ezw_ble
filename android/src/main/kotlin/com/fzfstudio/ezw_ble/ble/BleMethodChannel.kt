package com.fzfstudio.ezw_ble.ble

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.BleScan
import com.fzfstudio.ezw_ble.ble.models.BleSnRule
import com.fzfstudio.ezw_utils.extension.toUpperSnakeCase
import io.flutter.plugin.common.MethodChannel

/**
 * Android MethodChannel 方法枚举与分发器。
 *
 * 该文件只负责把 Flutter MethodChannel 参数转换为原生调用，不能承载扫描、连接、GATT 或
 * 自动回连逻辑。保持它独立可以避免 `BleChannel` 同时处理 MethodChannel 和 EventChannel。
 */
enum class BleMC {
    /** 返回当前 Android 系统版本。 */
    GET_PLATFORM_VERSION,
    /** 返回当前蓝牙状态缓存。 */
    BLE_STATE,
    /** 初始化 BLE 配置列表。 */
    INIT_CONFIGS,
    /** 开始扫描设备。 */
    START_SCAN,
    /** 停止扫描设备。 */
    STOP_SCAN,
    /** 主动连接指定设备。 */
    CONNECT_DEVICE,
    /** 标记设备进入业务鉴权中的预连接状态。 */
    DEVICE_PRE_CONNECTED,
    /** 标记设备业务鉴权成功并启用自动回连。 */
    DEVICE_CONNECTED,
    /** 补种 native 自动回连目标，不发起前台连接。 */
    ARM_AUTO_RECONNECT_TARGETS,
    /** 立即建立/复用所有目标的 native 直连，并保留调用来源。 */
    ACTIVATE_AUTO_RECONNECT_TARGETS,
    /** 辅助扫描重新看到目标时，唤醒 exact pre-physical passive owner。 */
    NOTIFY_AUTO_RECONNECT_TARGET_VISIBLE,
    /** 断开设备连接，可选移除系统绑定。 */
    DISCONNECT_DEVICE,
    /** 中性释放 endpoint runtime，保留持久自动回连 owner。 */
    RELEASE_DEVICE,
    /** 发送普通 GATT 指令。 */
    SEND_CMD,
    /** 发送不等待写入回调的 GATT 指令。 */
    SEND_CMD_NO_WAIT,
    /** 标记设备进入升级状态。 */
    ENTER_UPGRADE_STATE,
    /** 标记设备退出升级状态。 */
    QUITE_UPGRADE_STATE,
    /** 清理本地连接缓存。 */
    CLEAN_CONNECT_CACHE,
    /** 读取并清空原生自动回连/后台恢复事件。 */
    DRAIN_AUTO_RECONNECT_EVENTS,
    /** 重置插件蓝牙状态。 */
    RESET_BLE,
    /** 打开系统蓝牙设置页。 */
    OPEN_BLE_SETTINGS,
    /** 打开当前 App 设置页。 */
    OPEN_APP_SETTINGS,
    /** 未知或未支持的方法。 */
    UNKNOWN;

    companion object {
        /**
         * 将 Dart 侧 camelCase 方法名转换为 Android 枚举值。
         *
         * 未知方法会统一落到 `UNKNOWN`，避免平台侧因为新增 Dart 方法而直接抛异常。
         */
        fun from(method: String): BleMC =
            runCatching { valueOf(method.toUpperSnakeCase()) }.getOrDefault(UNKNOWN)
    }

    /**
     * 分发 MethodChannel 调用到 `BleManager`。
     *
     * 这里的流程只做三件事：解析参数、调用对应 manager 方法、向 Flutter 返回结果。
     * 任何需要跨回调维护状态的逻辑都必须放在 manager/coordinator 层。
     */
    fun handle(context: Context, arguments: Any?, result: MethodChannel.Result) {
        when (this) {
            GET_PLATFORM_VERSION -> {
                // 1. 平台版本是同步查询，直接返回。
                return result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            BLE_STATE -> {
                // 1. 蓝牙状态由 BleManager 统一缓存，避免在 channel 层重复读系统状态。
                return result.success(BleManager.instance.currentBleState)
            }
            INIT_CONFIGS -> {
                // 1. Dart 传入的是 List<Map>，这里转换成原生配置模型。
                val jsonMap = arguments as List<*>?
                val configs = jsonMap?.mapNotNull { (it as? Map<*, *>)?.toBleConfig() }

                // 2. 配置为空时保持幂等，不主动清空已有运行态。
                if (configs != null) {
                    BleManager.instance.initConfigs(configs)
                }
            }
            START_SCAN -> {
                // 1. 只解析扫描纯净模式开关，具体扫描状态由 BleManager 控制。
                val jsonMap = arguments as Map<*, *>?
                val turnOnPureModel = jsonMap?.get("turnOnPureModel") as? Boolean ?: false
                BleManager.instance.startScan(pureModel = turnOnPureModel)
            }
            STOP_SCAN -> {
                // 1. 停止扫描不需要额外参数。
                BleManager.instance.stopScan()
            }
            CONNECT_DEVICE -> {
                // 1. 主动连接参数必须显式解析，避免 `null` 进入底层状态机。
                val jsonMap = arguments as Map<*, *>?
                val belongConfig = jsonMap?.get("belongConfig") as? String ?: ""
                val uuid = jsonMap?.get("uuid") as? String ?: ""
                val name = jsonMap?.get("name") as? String ?: ""
                val sn = jsonMap?.get("sn") as? String ?: ""
                val afterUpgrade = jsonMap?.get("afterUpgrade") as Boolean? == true
                val directConnect = jsonMap?.get("directConnect") as Boolean? == true

                // 2. 旧 API 约定 uuid/sn 必须同时存在。参数非法时必须让 Future 失败，
                // 否则 Dart 会等待一个永远不会产生的 connectStatus 终态。
                if (uuid.isEmpty() || sn.isEmpty()) {
                    return result.error(
                        "INVALID_CONNECT_ARGUMENTS",
                        "connectDevice requires non-empty uuid and sn on Android",
                        mapOf("uuid" to uuid, "name" to name, "sn" to sn, "belongConfig" to belongConfig),
                    )
                }
                BleManager.instance.connect(
                    belongConfig,
                    uuid,
                    name,
                    sn,
                    afterUpgrade = afterUpgrade,
                    directConnect = directConnect,
                )
            }
            DEVICE_PRE_CONNECTED -> {
                // 1. Dart 业务认证开始后，原生进入有界宽限期。
                val uuid = arguments as? String ?: ""
                BleManager.instance.setPreConnected(uuid)
            }
            DEVICE_CONNECTED -> {
                // 1. Dart 业务认证成功后，原生才允许 arm 自动回连。
                val uuid = arguments as? String ?: ""
                BleManager.instance.setConnected(uuid)
            }
            ARM_AUTO_RECONNECT_TARGETS -> {
                // 1. 旧缓存/进程恢复时，Dart 只补种长期回连意图，不打开 GATT。
                val jsonArray = arguments as List<*>?
                val targets = jsonArray?.mapNotNull { (it as? Map<*, *>)?.toReconnectSeed() }
                    ?: emptyList()
                BleManager.instance.armAutoReconnectTargets(targets)
            }
            ACTIVATE_AUTO_RECONNECT_TARGETS -> {
                // 1. 新 API 使用 Map 携带 targets + source；未知来源必须向后兼容降级。
                val jsonMap = arguments as? Map<*, *>
                val targets = (jsonMap?.get("devices") as? List<*>)
                    ?.mapNotNull { (it as? Map<*, *>)?.toReconnectSeed() }
                    ?: emptyList()
                val source = BleConnectSource.fromFlutterValue(jsonMap?.get("source") as? String)
                return result.success(
                    BleManager.instance.activateAutoReconnectTargets(targets, source)
                        .map { it.toFlutterMap() },
                )
            }
            NOTIFY_AUTO_RECONNECT_TARGET_VISIBLE -> {
                // 只传递可见信号；manager/supervisor 决定当前 exact owner 是否可被唤醒。
                val jsonMap = arguments as? Map<*, *>
                val uuid = jsonMap?.get("uuid") as? String ?: ""
                val name = jsonMap?.get("name") as? String ?: ""
                return result.success(
                    BleManager.instance.notifyAutoReconnectTargetVisible(uuid, name),
                )
            }
            DISCONNECT_DEVICE -> {
                // 1. 主动断连必须透传 removeBond，移除设备时需要清理系统绑定。
                val jsonMap = arguments as Map<*, *>?
                val uuid = jsonMap?.get("uuid") as? String ?: ""
                val removeBond = jsonMap?.get("removeBond") as Boolean? ?: false
                BleManager.instance.disconnect(uuid, removeBond)
            }
            RELEASE_DEVICE -> {
                // dispose/reset 只释放 runtime；禁止复用 disconnect 的持久 owner 删除语义。
                val jsonMap = arguments as Map<*, *>?
                val uuid = jsonMap?.get("uuid") as? String ?: ""
                val name = jsonMap?.get("name") as? String ?: ""
                BleManager.instance.releaseDevice(uuid, name)
            }
            SEND_CMD -> {
                // 1. GATT 写入由 BleManager 按 uuid 队列化，channel 层只传递 payload。
                val jsonMap = arguments as Map<*, *>?
                val uuid = jsonMap?.get("uuid") as? String ?: ""
                val data = jsonMap?.get("data") as ByteArray? ?: byteArrayOf()
                val psType = jsonMap?.get("psType") as Int? ?: 0
                BleManager.instance.sendCmd(uuid, data, psType)
            }
            SEND_CMD_NO_WAIT -> {
                // 1. OTA no-wait 写入仍由 BleManager 根据 psType 选择发送策略。
                val jsonMap = arguments as Map<*, *>?
                val uuid = jsonMap?.get("uuid") as? String ?: ""
                val data = jsonMap?.get("data") as ByteArray? ?: byteArrayOf()
                val psType = jsonMap?.get("psType") as Int? ?: 0
                BleManager.instance.sendCmdNoWait(uuid, data, psType)
            }
            ENTER_UPGRADE_STATE -> {
                // 1. 升级态会影响断连后的重连清理策略。
                val uuid = arguments as? String ?: ""
                BleManager.instance.enterUpgradeState(uuid)
            }
            QUITE_UPGRADE_STATE -> {
                // 1. 退出升级态后，后续普通连接会恢复常规清理流程。
                val uuid = arguments as? String ?: ""
                BleManager.instance.quiteUpgradeState(uuid)
            }
            CLEAN_CONNECT_CACHE -> {
                // 1. 调试/恢复入口：清理插件侧连接缓存。
                BleManager.instance.cleanConnectCache()
            }
            DRAIN_AUTO_RECONNECT_EVENTS -> {
                // 1. 自动回连事件需要返回给 Dart，因此这里提前 return。
                return result.success(BleManager.instance.drainAutoReconnectEvents())
            }
            RESET_BLE -> {
                // 1. 重置由 BleManager 统一释放扫描、连接、队列和监听资源。
                BleManager.instance.reset()
            }
            OPEN_BLE_SETTINGS -> {
                // 1. 系统设置页必须使用新 task，否则插件上下文可能不是 Activity。
                val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            }
            OPEN_APP_SETTINGS -> {
                // 1. App 设置页用于用户手动修复系统权限。
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", context.packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            }
            else -> null
        }

        // 2. 未提前返回的方法保持原有 API 语义：异步结果通过 EventChannel 上报。
        result.success(null)
    }
}

/**
 * 将 Dart `BleConfig` JSON 转成 Android 模型。
 *
 * 解析保持宽松：缺失的可选字段使用默认值，缺失关键字段则返回 null 让上层跳过该配置。
 */
private fun Map<*, *>.toBleConfig(): BleConfig? {
    // 1. 配置名和扫描规则是必需项，缺失时不能创建有效配置。
    val name = get("name") as? String ?: return null
    val scan = (get("scan") as? Map<*, *>)?.toBleScan() ?: return null

    // 2. 私有服务决定 GATT readiness，缺失时不能继续连接。
    val privateServices = (get("privateServices") as? List<*>)
        ?.mapNotNull { (it as? Map<*, *>)?.toBlePrivateService() }
        ?: return null

    // 3. 自动回连字段必须保留默认值兼容旧 Dart 配置。
    return BleConfig(
        name = name,
        scan = scan,
        privateServices = privateServices,
        initiateBinding = get("initiateBinding") as? Boolean ?: false,
        connectTimeout = get("connectTimeout").toDoubleOrDefault(15000.0),
        upgradeSwapTime = get("upgradeSwapTime").toDoubleOrDefault(60000.0),
        mtu = get("mtu").toIntOrDefault(247),
        autoReconnect = get("autoReconnect") as? Boolean ?: false,
        autoReconnectMaxAttempts = get("autoReconnectMaxAttempts").toIntOrDefault(0),
        autoReconnectUseNativePassive = get("autoReconnectUseNativePassive") as? Boolean ?: true,
    )
}

/**
 * 将 Dart `BleDevice` JSON 转成 native 自动回连 seed。
 *
 * 该结构只用于建立长期回连意图，不代表当前 GATT 已连接。
 */
private fun Map<*, *>.toReconnectSeed(): BleReconnectSeed? {
    val belongConfig = get("belongConfig") as? String ?: return null
    val uuid = get("uuid") as? String ?: return null
    val name = get("name") as? String ?: ""
    val sn = get("sn") as? String ?: ""
    val rssi = get("rssi").toIntOrDefault(0)
    // activation 需要保留空 uuid 让 manager 返回 rejected；arm-only 仍由 manager 严格过滤。
    if (belongConfig.isBlank()) return null
    return BleReconnectSeed(
        belongConfig = belongConfig,
        uuid = uuid,
        name = name,
        sn = sn,
        rssi = rssi,
    )
}

/**
 * 将 Dart `BleScan` JSON 转成 Android 扫描规则。
 *
 * `matchCount` 是 G2 左右腿聚合展示的关键字段，默认仍保持 1 兼容单设备配置。
 */
private fun Map<*, *>.toBleScan(): BleScan {
    // 1. 名称过滤器可以为空，表示该配置不按 name 前缀过滤。
    val nameFilters = (get("nameFilters") as? List<*>)
        ?.mapNotNull { it as? String }
        ?: emptyList()

    // 2. SN 规则是可选项；没有 SN 规则时只走 name/mac 匹配。
    return BleScan(
        nameFilters = nameFilters,
        snRule = (get("snRule") as? Map<*, *>)?.toBleSnRule(),
        matchCount = get("matchCount").toIntOrDefault(1),
    )
}

/**
 * 将 Dart `BleSnRule` JSON 转成 Android SN 解析规则。
 *
 * 数字字段使用安全转换，避免 Dart 侧 int/double 互转导致类型不匹配。
 */
private fun Map<*, *>.toBleSnRule(): BleSnRule {
    // 1. SN 解析依赖 byteLength/startSubIndex，缺失时使用 0 让扫描逻辑自然不命中。
    return BleSnRule(
        byteLength = get("byteLength").toIntOrDefault(0),
        startSubIndex = get("startSubIndex").toIntOrDefault(0),
        replaceRex = get("replaceRex") as? String ?: "",
        filters = (get("filters") as? List<*>)
            ?.mapNotNull { it as? String }
            ?: emptyList(),
    )
}

/**
 * 将 Dart `BlePrivateService` JSON 转成 Android 私有服务模型。
 *
 * service UUID 是唯一必需项；读写特征可以为空，由 GATT pipeline 按配置类型判断 readiness。
 */
private fun Map<*, *>.toBlePrivateService(): BlePrivateService? {
    // 1. 没有 service UUID 时无法参与服务发现，直接跳过该条配置。
    val service = get("service") as? String ?: return null

    // 2. type 用于区分默认/OTA/stream/file 私有服务。
    return BlePrivateService(
        service = service,
        writeChars = get("writeChars") as? String,
        readChars = get("readChars") as? String,
        type = get("type").toIntOrDefault(0),
    )
}

/**
 * 宽松地把 MethodChannel 数值转换成 Int。
 *
 * Flutter 标准通道在不同平台/调用点可能把数字编码为 Int、Long、Double 或 Float。
 */
private fun Any?.toIntOrDefault(default: Int): Int {
    // 1. 覆盖所有 Number 子类，避免配置解析因为数字装箱类型差异失败。
    return when (this) {
        is Int -> this
        is Long -> toInt()
        is Double -> toInt()
        is Float -> toInt()
        is Number -> toInt()
        else -> default
    }
}

/**
 * 宽松地把 MethodChannel 数值转换成 Double。
 *
 * 连接超时/升级等待时间在 Dart 侧可能以 int 或 double 形式进入原生。
 */
private fun Any?.toDoubleOrDefault(default: Double): Double {
    // 1. 覆盖所有 Number 子类，保持旧配置 JSON 的兼容性。
    return when (this) {
        is Double -> this
        is Float -> toDouble()
        is Int -> toDouble()
        is Long -> toDouble()
        is Number -> toDouble()
        else -> default
    }
}
