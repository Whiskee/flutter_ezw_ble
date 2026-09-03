package com.fzfstudio.ezw_ble.ble

import android.content.Context
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.BleScan
import com.fzfstudio.ezw_ble.ble.models.BleSecurityGate
import com.fzfstudio.ezw_ble.ble.models.BleSnRule
import org.json.JSONArray
import org.json.JSONObject

/**
 * Android native auto reconnect 持久化仓库。
 *
 * 该类只负责 SharedPreferences 与轻量 JSON 编解码：保存配置快照、自动回连目标和 native
 * 事件缓冲。它不发起扫描/连接，也不改变 `BleManager` 的运行态，避免 manager 同时承担存储
 * 细节和 BLE 状态机职责。
 */
internal class BleReconnectStore {
    /** SharedPreferences 文件名，保持旧版本存储兼容。 */
    private val prefsName = "flutter_ezw_ble_auto_reconnect"

    /** 持久化配置列表 key。 */
    private val configsKey = "configs"

    /** 持久化回连目标列表 key。 */
    private val targetsKey = "targets"

    /** native 自动回连/后台恢复事件缓冲 key。 */
    private val eventsKey = "events"

    /**
     * 保存 BLE 配置快照。
     *
     * Android 进程被系统拉起后，Dart 可能尚未完成 `initConfigs`，因此 native 需要一份最小配置
     * 快照来恢复自动回连链路。
     */
    fun persistConfigs(context: Context?, configs: List<BleConfig>) {
        // 1. 没有 context 时不能写 SharedPreferences，直接保持内存态。
        val prefs = context?.getSharedPreferences(prefsName, Context.MODE_PRIVATE) ?: return

        // 2. 配置以 JSON 数组保存，字段保持与 MethodChannel 模型一致，便于恢复。
        prefs.edit()
            .putString(configsKey, JSONArray().apply {
                configs.forEach { config -> put(config.toPersistedJson()) }
            }.toString())
            .apply()
    }

    /**
     * 恢复 BLE 配置快照。
     *
     * 返回 null 表示没有可用快照或快照损坏；调用方决定是否写入当前 manager 配置。
     */
    fun restoreConfigs(context: Context?): List<BleConfig>? {
        // 1. context 或原始 JSON 缺失时，不做任何恢复。
        val prefs = context?.getSharedPreferences(prefsName, Context.MODE_PRIVATE) ?: return null
        val raw = prefs.getString(configsKey, null) ?: return null

        // 2. 损坏配置不抛给 manager，避免启动恢复路径被持久化脏数据打断。
        return runCatching {
            val configs = mutableListOf<BleConfig>()
            val json = JSONArray(raw)
            for (index in 0 until json.length()) {
                json.optJSONObject(index)?.toBleConfig()?.let { configs.add(it) }
            }
            configs
        }.getOrNull()
    }

    /**
     * 记录 native 自动回连或后台恢复事件。
     *
     * Dart EventChannel 未恢复时，事件先进入持久化缓冲；Dart 之后通过 drain 方法补读。
     */
    fun recordEvent(
        context: Context?,
        type: String,
        uuid: String = "",
        name: String = "",
        detail: String = "",
    ) {
        // 1. 无 context 时不能落盘；事件只作为诊断信息，不影响连接状态机。
        val prefs = context?.getSharedPreferences(prefsName, Context.MODE_PRIVATE) ?: return
        val events = JSONArray(prefs.getString(eventsKey, "[]") ?: "[]")

        // 2. 事件字段保持扁平 Map，方便 Dart 直接展示/上报。
        events.put(JSONObject().apply {
            put("type", type)
            put("uuid", uuid)
            put("name", name)
            put("detail", detail)
            put("timestamp", System.currentTimeMillis() / 1000.0)
        })

        // 3. 只保留最近 50 条，避免异常循环无限写入 SharedPreferences。
        val trimmed = JSONArray()
        val start = (events.length() - 50).coerceAtLeast(0)
        for (index in start until events.length()) {
            trimmed.put(events.get(index))
        }
        prefs.edit().putString(eventsKey, trimmed.toString()).apply()
    }

    /**
     * 读取并清空 native 事件缓冲。
     *
     * drain 语义保证事件不会重复回放给 Dart。
     */
    fun drainEvents(context: Context?): List<Map<String, Any>> {
        // 1. 没有 context 时返回空列表，保持 MethodChannel 调用幂等。
        val prefs = context?.getSharedPreferences(prefsName, Context.MODE_PRIVATE) ?: return emptyList()
        val events = JSONArray(prefs.getString(eventsKey, "[]") ?: "[]")
        val output = mutableListOf<Map<String, Any>>()

        // 2. 逐条转换为 Flutter 标准通道可传输的 Map。
        for (index in 0 until events.length()) {
            val event = events.optJSONObject(index) ?: continue
            output.add(
                mapOf(
                    "type" to event.optString("type"),
                    "uuid" to event.optString("uuid"),
                    "name" to event.optString("name"),
                    "detail" to event.optString("detail"),
                    "timestamp" to event.optDouble("timestamp"),
                ),
            )
        }

        // 3. 成功读取后清空缓冲，避免下一次 drain 重复返回。
        prefs.edit().remove(eventsKey).apply()
        return output
    }

    /**
     * 新增或更新一个持久化回连目标。
     *
     * 同一 uuid 只保留最新目标，避免旧配置在蓝牙恢复时误触发连接。
     */
    fun upsertTarget(context: Context?, device: BleDevice) {
        // 1. 读取现有目标并删除同 uuid 旧记录。
        val targets = targets(context)
            .filterNot { it.uuid.equals(device.uuid, ignoreCase = true) }
            .toMutableList()

        // 2. 只持久化身份和配置名；GATT/service/char 运行态永远不能落盘。
        targets.add(
            BlePersistedReconnectTarget(
                belongConfig = device.belongConfig.name,
                uuid = device.uuid,
                name = device.name,
                sn = device.sn,
            ),
        )
        saveTargets(context, targets)
    }

    /**
     * 移除一个持久化回连目标。
     *
     * 用户主动断开或移除设备时调用，防止后续系统断连回调重新 arm 回连。
     */
    fun removeTarget(context: Context?, uuid: String) {
        // 1. 空 uuid 无法定位目标，直接保持幂等。
        if (uuid.isBlank()) {
            return
        }

        // 2. 过滤同 uuid 目标并保存剩余列表。
        saveTargets(
            context,
            targets(context).filterNot {
                it.uuid.equals(uuid, ignoreCase = true)
            },
        )
    }

    /**
     * 清空所有持久化回连目标。
     *
     * reset/remove-all 语义要求彻底取消 native 自动回连意图。
     */
    fun clearTargets(context: Context?) {
        // 1. 只删除 targets，不影响配置快照和事件缓冲。
        context?.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            ?.edit()
            ?.remove(targetsKey)
            ?.apply()
    }

    /**
     * 配置删除/关闭 autoReconnect 时移除该配置全部持久 owner，并返回被撤销 endpoint。
     * 先读出 removed 再一次性保存 remaining，避免逐条 apply 暴露中间态。
     */
    fun removeTargetsForConfigs(context: Context?, configNames: Set<String>): Set<String> {
        if (configNames.isEmpty()) {
            return emptySet()
        }
        val existing = targets(context)
        val removed = existing.filter { it.belongConfig in configNames }
        saveTargets(context, existing.filterNot { it.belongConfig in configNames })
        return removed.map { it.uuid }.toSet()
    }

    /**
     * 读取全部持久化回连目标。
     *
     * 损坏数据会降级为空列表，避免持久化脏数据破坏启动流程。
     */
    fun targets(context: Context?): MutableList<BlePersistedReconnectTarget> {
        // 1. 缺少 context 时没有可读存储。
        val prefs = context?.getSharedPreferences(prefsName, Context.MODE_PRIVATE) ?: return mutableListOf()
        val raw = prefs.getString(targetsKey, "[]") ?: "[]"

        // 2. 逐条解析目标；单条损坏时跳过，不影响其它目标。
        return runCatching {
            val targets = mutableListOf<BlePersistedReconnectTarget>()
            val json = JSONArray(raw)
            for (index in 0 until json.length()) {
                val item = json.optJSONObject(index) ?: continue
                targets.add(
                    BlePersistedReconnectTarget(
                        belongConfig = item.optString("belongConfig"),
                        uuid = item.optString("uuid"),
                        name = item.optString("name"),
                        sn = item.optString("sn"),
                    ),
                )
            }
            targets
        }.getOrDefault(mutableListOf())
    }

    /**
     * 保存持久化回连目标列表。
     *
     * 所有目标写入统一走这里，保证磁盘结构一致。
     */
    private fun saveTargets(context: Context?, targets: List<BlePersistedReconnectTarget>) {
        // 1. 没有 context 时无法落盘，调用方仍保持内存任务状态。
        val prefs = context?.getSharedPreferences(prefsName, Context.MODE_PRIVATE) ?: return

        // 2. 按稳定字段写入 JSON，避免未来数据类调整影响旧版本解析。
        prefs.edit()
            .putString(targetsKey, JSONArray().apply {
                targets.forEach { target ->
                    put(JSONObject().apply {
                        put("belongConfig", target.belongConfig)
                        put("uuid", target.uuid)
                        put("name", target.name)
                        put("sn", target.sn)
                    })
                }
            }.toString())
            .apply()
    }

    /**
     * 将 BleConfig 转成持久化 JSON。
     *
     * 字段覆盖自动回连策略，保证进程恢复时 native 能继续使用同一套连接参数。
     */
    private fun BleConfig.toPersistedJson(): JSONObject {
        // 1. 顶层字段与 Dart BleConfig 保持同名，便于排查持久化内容。
        return JSONObject().apply {
            put("name", name)
            put("scan", scan.toPersistedJson())
            put("privateServices", JSONArray().apply {
                privateServices.forEach { service -> put(service.toPersistedJson()) }
            })
            put("securityGate", securityGate?.toPersistedJson())
            put("initiateBinding", initiateBinding)
            put("connectTimeout", connectTimeout)
            put("upgradeSwapTime", upgradeSwapTime)
            put("mtu", mtu)
            put("autoReconnect", autoReconnect)
            put("autoReconnectMaxAttempts", autoReconnectMaxAttempts)
            put("autoReconnectUseNativePassive", autoReconnectUseNativePassive)
            put("androidHighReliabilityMode", androidHighReliabilityMode)
        }
    }

    /** 门禁属于 native 进程恢复连接的必要配置，不能只保留在 Dart 内存中。 */
    private fun BleSecurityGate.toPersistedJson(): JSONObject = JSONObject().apply {
        put("service", service)
        put("writeChars", writeChars)
    }

    /**
     * 将 BleScan 转成持久化 JSON。
     *
     * matchCount 必须保留，G2 左右腿扫描聚合依赖该字段。
     */
    private fun BleScan.toPersistedJson(): JSONObject {
        // 1. nameFilters/snRule/matchCount 是恢复扫描目标识别的最小信息。
        return JSONObject().apply {
            put("nameFilters", JSONArray().apply {
                nameFilters.forEach { filter -> put(filter) }
            })
            put("snRule", snRule?.toPersistedJson())
            put("matchCount", matchCount)
        }
    }

    /**
     * 将 BleSnRule 转成持久化 JSON。
     *
     * SN 解析规则用于恢复后重新识别设备身份。
     */
    private fun BleSnRule.toPersistedJson(): JSONObject {
        // 1. filters 需要完整保存，否则恢复后可能错误展示未配对设备。
        return JSONObject().apply {
            put("byteLength", byteLength)
            put("startSubIndex", startSubIndex)
            put("replaceRex", replaceRex)
            put("filters", JSONArray().apply {
                filters.forEach { filter -> put(filter) }
            })
        }
    }

    /**
     * 将 BlePrivateService 转成持久化 JSON。
     *
     * 私有服务列表决定 GATT readiness，回连恢复后必须重新发现并注册 notify。
     */
    private fun BlePrivateService.toPersistedJson(): JSONObject {
        // 1. write/read/type 保持可空兼容，具体 readiness 由 GATT pipeline 判断。
        return JSONObject().apply {
            put("service", service)
            put("writeChars", writeChars)
            put("readChars", readChars)
            put("type", type)
        }
    }

    /**
     * 从持久化 JSON 恢复 BleConfig。
     *
     * 缺少 scan 或 privateServices 时返回 null，避免创建不可连接配置。
     */
    private fun JSONObject.toBleConfig(): BleConfig? {
        // 1. scan/privateServices 是恢复连接的必需字段。
        val scanJson = optJSONObject("scan") ?: return null
        val servicesJson = optJSONArray("privateServices") ?: return null
        val services = mutableListOf<BlePrivateService>()

        // 2. 单个服务解析失败时跳过，剩余服务仍可参与 readiness。
        for (index in 0 until servicesJson.length()) {
            servicesJson.optJSONObject(index)?.toBlePrivateService()?.let { services.add(it) }
        }

        // 3. 自动回连字段使用默认值兼容旧版本持久化数据。
        return BleConfig(
            name = optString("name"),
            scan = scanJson.toBleScan(),
            privateServices = services,
            securityGate = optJSONObject("securityGate")?.toBleSecurityGate(),
            initiateBinding = optBoolean("initiateBinding", false),
            connectTimeout = optDouble("connectTimeout", 15000.0),
            upgradeSwapTime = optDouble("upgradeSwapTime", 60000.0),
            mtu = optInt("mtu", 247),
            autoReconnect = optBoolean("autoReconnect", false),
            autoReconnectMaxAttempts = optInt("autoReconnectMaxAttempts", 0),
            autoReconnectUseNativePassive = optBoolean("autoReconnectUseNativePassive", true),
            androidHighReliabilityMode = optBoolean("androidHighReliabilityMode", false),
        )
    }

    /** 损坏或旧快照中的空门禁按未配置处理，继续兼容旧固件。 */
    private fun JSONObject.toBleSecurityGate(): BleSecurityGate? {
        val service = optString("service")
        val writeChars = optString("writeChars")
        if (service.isBlank() || writeChars.isBlank()) {
            return null
        }
        return BleSecurityGate(service = service, writeChars = writeChars)
    }

    /**
     * 从持久化 JSON 恢复 BleScan。
     *
     * 缺失字段使用与 Dart/MethodChannel 相同的默认值。
     */
    private fun JSONObject.toBleScan(): BleScan {
        // 1. snRule 可为空；没有 SN 规则时只按名称/MAC 识别。
        return BleScan(
            nameFilters = optJSONArray("nameFilters").toStringList(),
            snRule = optJSONObject("snRule")?.toBleSnRule(),
            matchCount = optInt("matchCount", 1),
        )
    }

    /**
     * 从持久化 JSON 恢复 BleSnRule。
     *
     * 数字字段缺失时使用 0，使无效规则自然不命中。
     */
    private fun JSONObject.toBleSnRule(): BleSnRule {
        // 1. filters 缺失时为空列表，表示不按 SN 标识过滤。
        return BleSnRule(
            byteLength = optInt("byteLength", 0),
            startSubIndex = optInt("startSubIndex", 0),
            replaceRex = optString("replaceRex", ""),
            filters = optJSONArray("filters").toStringList(),
        )
    }

    /**
     * 从持久化 JSON 恢复 BlePrivateService。
     *
     * service UUID 是必需项，缺失时该服务不能参与 GATT 初始化。
     */
    private fun JSONObject.toBlePrivateService(): BlePrivateService? {
        // 1. service 为空表示损坏或旧数据，跳过该服务。
        val service = optString("service")
        if (service.isBlank()) {
            return null
        }

        // 2. write/read 允许为空，保持与配置模型兼容。
        return BlePrivateService(
            service = service,
            writeChars = optString("writeChars").takeIf { it.isNotBlank() },
            readChars = optString("readChars").takeIf { it.isNotBlank() },
            type = optInt("type", 0),
        )
    }

    /**
     * 将 JSON 字符串数组恢复为 Kotlin List。
     *
     * 空值和空字符串都会被过滤，避免扫描规则出现无意义 filter。
     */
    private fun JSONArray?.toStringList(): List<String> {
        // 1. 缺失数组时返回空列表。
        if (this == null) {
            return emptyList()
        }

        // 2. 只保留非空字符串。
        val output = mutableListOf<String>()
        for (index in 0 until length()) {
            optString(index).takeIf { it.isNotEmpty() }?.let { output.add(it) }
        }
        return output
    }
}
