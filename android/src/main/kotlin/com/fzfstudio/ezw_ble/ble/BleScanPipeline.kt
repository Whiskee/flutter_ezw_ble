package com.fzfstudio.ezw_ble.ble

import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import com.fzfstudio.ezw_ble.ble.extension.toBleDevice
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BleSnRule
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import java.util.UUID
import java.util.regex.Pattern

/**
 * Android 扫描结果解析与聚合管线。
 *
 * 该类负责把系统 `ScanResult` 转成插件的 `BleDevice`：执行 name filter、SN 解析、纯净模式、
 * scan response 补 SN、matchCount 聚合，以及 scan-then-connect 命中通知。`BleManager` 只负责
 * 启停扫描和接收最终聚合结果。
 */
internal class BleScanPipeline(
    /** 当前注入的 BLE 配置列表。 */
    private val bleConfigs: () -> List<BleConfig>,
    /** 是否处于纯净扫描模式。 */
    private val scanPureMode: () -> Boolean,
    /** 本轮扫描缓存，供 matchCount 聚合和 connect 可见性判断复用。 */
    private val scanResultTemp: MutableList<BleDevice>,
    /** 扫描过程中定期淘汰已经超时的 scan-then-connect 请求。 */
    private val expirePendingScanConnects: () -> Unit,
    /** 扫描命中目标后继续推进待连接请求。 */
    private val tryConnectFromPendingScan: (BleDevice) -> Unit,
    /** 将已经按 SN 聚合好的设备列表发送给 Flutter。 */
    private val emitMatchDevices: (String, List<BleDevice>) -> Unit,
    /** 将系统异步扫描失败交还 manager 按 exact generation 收口。 */
    private val onScanFailed: (Int) -> Unit,
    /** 统一日志出口。 */
    private val sendLog: (BleLoggerTag, String) -> Unit,
) : ScanCallback() {

    /**
     * 处理单条扫描结果。
     *
     * Android 可能先返回不带完整 scan response 的广播包，再返回带 SN 的包，因此同一 address
     * 不能简单去重后丢弃；当缓存 SN 还是 name 兜底值时，需要允许后续 scan response 覆盖。
     */
    override fun onScanResult(callbackType: Int, result: ScanResult) {
        try {
            // 1. 优先使用 scan record 中的广播名称。Android 的 BluetoothDevice.name
            // 依赖系统缓存/配对历史，首次扫描或重装 App 后经常为空；只看它会导致 nameFilters
            // 完全匹配不到，最终表现为“搜索没有结果”。
            val device = result.device
            val advertisedName = resolveAdvertisedName(result)
            if (advertisedName.isNullOrEmpty()) {
                return
            }

            // 2. 使用配置的 nameFilters 找到该广播对应的设备配置。
            val bleConfig = resolveConfigForName(advertisedName) ?: return

            // 3. 已缓存设备仍可能需要用 scan response 覆盖 SN，不能直接忽略。
            val cachedScanDevice = synchronized(scanResultTemp) {
                scanResultTemp.firstOrNull { it.uuid == device.address }
            }
            if (cachedScanDevice != null) {
                updateCachedDeviceFromScanResponseIfNeeded(
                    cachedDevice = cachedScanDevice,
                    result = result,
                    bleConfig = bleConfig,
                    advertisedName = advertisedName,
                )
                return
            }

            // 4. 纯净模式不解析 SN/MAC，直接用随机 SN 作为单条扫描结果标识。
            if (scanPureMode()) {
                val deviceSn = UUID.randomUUID().toString()
                val bleDevice = device.toBleDevice(bleConfig, advertisedName, deviceSn, result.rssi)
                cacheAndRouteDevice(bleDevice)
                emitMatchDevices(deviceSn, listOf(bleDevice))
                return
            }

            // 5. 普通模式按 snRule 解析 SN，并应用 filters 过滤非目标设备。
            val deviceSn = resolveDeviceSn(
                bleConfig = bleConfig,
                advertisedName = advertisedName,
                scanRecordBytes = result.scanRecord?.bytes,
            ) ?: return

            // 6. 进入统一缓存/待连接命中/扫描结果聚合流程。
            val bleDevice = device.toBleDevice(bleConfig, advertisedName, deviceSn, result.rssi)
            cacheAndRouteDevice(bleDevice)
            emitIfMatchCountSatisfied(bleConfig, deviceSn, bleDevice)
        } catch (error: Exception) {
            sendLog(BleLoggerTag.e, "Start scan: scanning error = ${error.message}")
        }
    }

    /**
     * 输出批量扫描日志。
     *
     * 当前插件不使用 batch 结果驱动业务，仅保留日志以便排查 Android 扫描栈行为。
     */
    override fun onBatchScanResults(results: List<ScanResult>) {
        // 1. batch 模式下仍只记录系统返回，避免绕过单条扫描管线造成行为差异。
        sendLog(BleLoggerTag.d, "Start scan: batch = $results")
    }

    /**
     * 输出系统扫描失败日志。
     *
     * 失败码保留原始整数，方便结合 Android 官方错误码或厂商日志排查。
     */
    override fun onScanFailed(errorCode: Int) {
        // 1. 扫描失败不在 pipeline 内重试，先让 manager 清理状态并通知 Dart。
        onScanFailed(errorCode)
        sendLog(BleLoggerTag.e, "Start scan: error = $errorCode")
    }

    /**
     * 按设备名匹配配置。
     *
     * 一个插件实例可能同时持有 G1/G2/Ring 等多套配置，扫描阶段必须先找到所属配置。
     */
    private fun resolveConfigForName(advertisedName: String): BleConfig? {
        // 1. nameFilters 任一命中即认为属于该配置。
        return bleConfigs().firstOrNull { config ->
            config.scan.nameFilters.firstOrNull { filter -> advertisedName.contains(filter) } != null
        }
    }

    /**
     * 解析当前扫描回调的稳定设备名。
     *
     * `ScanRecord.deviceName` 来自本次广播，更适合扫描过滤；`BluetoothDevice.name` 只是系统
     * 缓存名，可能为空或滞后，只能作为 fallback。
     */
    private fun resolveAdvertisedName(result: ScanResult): String? {
        // 1. 广播 local name 是未连接设备最可靠的扫描阶段名称来源。
        result.scanRecord?.deviceName?.takeIf { it.isNotBlank() }?.let { return it }

        // 2. 如果广告包没有名称，再退回系统缓存名。
        return result.device.name?.takeIf { it.isNotBlank() }
    }

    /**
     * 使用后续 scan response 修正缓存中的 SN。
     *
     * R1 类设备的 SN 可能不在第一包广播里；如果缓存 SN 仍等于 name，说明之前只是兜底值，
     * 后续解析出真实 SN 时需要替换缓存并重新触发 matchCount 判断。
     */
    private fun updateCachedDeviceFromScanResponseIfNeeded(
        cachedDevice: BleDevice,
        result: ScanResult,
        bleConfig: BleConfig,
        advertisedName: String,
    ) {
        // 1. 纯净模式或缓存已经有真实 SN 时，不需要覆盖。
        if (scanPureMode() || cachedDevice.sn != cachedDevice.name) {
            return
        }

        // 2. 没有 snRule 无法解析后续 scan response。
        val snRule = bleConfig.scan.snRule ?: return
        val parsedSn = parseDataToObtainSn(result.scanRecord?.bytes, snRule)
        logRingSnAdvertisementDebug(
            name = advertisedName,
            scanRecordBytes = result.scanRecord?.bytes,
            snRule = snRule,
            parsedSn = parsedSn,
        )

        // 3. 只有解析结果满足 filters 时才替换缓存，避免把无关广播写成目标设备。
        val hasValidSn = parsedSn.isNotEmpty() &&
            (snRule.filters.isEmpty() || snRule.filters.any { parsedSn.contains(it) })
        if (!hasValidSn || parsedSn == cachedDevice.sn) {
            return
        }

        // 4. 使用真实 SN 重建 BleDevice，并替换同 address 的旧缓存。
        val bleDevice = result.device.toBleDevice(bleConfig, advertisedName, parsedSn, result.rssi)
        synchronized(scanResultTemp) {
            scanResultTemp.removeAll { it.uuid == result.device.address }
            scanResultTemp.add(bleDevice)
        }

        // 5. 缓存替换后重新推进待连接和 matchCount 聚合。
        expirePendingScanConnects()
        tryConnectFromPendingScan(bleDevice)
        emitIfMatchCountSatisfied(bleConfig, parsedSn, bleDevice)
    }

    /**
     * 解析当前广播的设备 SN。
     *
     * 没有 `snRule` 时沿用设备名作为 SN；有规则时必须按 slice/filter/replaceRex 处理。
     */
    private fun resolveDeviceSn(
        bleConfig: BleConfig,
        advertisedName: String,
        scanRecordBytes: ByteArray?,
    ): String? {
        // 1. 默认用设备名兜底，保持历史行为。
        val snRule = bleConfig.scan.snRule ?: return advertisedName
        val parsedSn = parseDataToObtainSn(scanRecordBytes, snRule)
        logRingSnAdvertisementDebug(advertisedName, scanRecordBytes, snRule, parsedSn)

        // 2. 解析成功且满足 filter 时使用真实 SN，否则保持兜底并进入过滤判断。
        val deviceSn = if (
            parsedSn.isNotEmpty() &&
            (snRule.filters.isEmpty() || snRule.filters.any { parsedSn.contains(it) })
        ) {
            parsedSn
        } else {
            advertisedName
        }

        // 3. 有 filter 的配置必须命中目标标识，不命中则丢弃本条广播。
        val isInvalid = deviceSn.isEmpty() ||
            (snRule.filters.isNotEmpty() && !snRule.filters.any { deviceSn.contains(it) })
        if (!isInvalid) {
            return deviceSn
        }

        // 4. 对重点排查设备保留 drop 日志，避免 SN rule 配错时完全无迹可循。
        if (
            advertisedName.contains("EVEN R1") ||
            advertisedName.contains("B210") ||
            advertisedName.contains("B290") ||
            advertisedName.contains("DfuTarg")
        ) {
            sendLog(
                BleLoggerTag.e,
                "Start scan: drop by snRule, name=$advertisedName, parsedSn=$parsedSn, finalSn=$deviceSn, filters=${snRule.filters}",
            )
        }
        return null
    }

    /**
     * 缓存扫描设备并推进待连接请求。
     *
     * 扫描缓存是 connect 可见性、matchCount 聚合和 name 补齐的共同数据源。
     */
    private fun cacheAndRouteDevice(bleDevice: BleDevice) {
        // 1. 先加入缓存，让后续 connect 可见性查询能看到本条扫描结果。
        scanResultTemp.add(bleDevice)

        // 2. 先淘汰超时请求，再用当前设备尝试命中待连接请求。
        expirePendingScanConnects()
        tryConnectFromPendingScan(bleDevice)
    }

    /**
     * 根据 matchCount 决定是否发送扫描结果。
     *
     * G2 左右腿类设备需要等同 SN 的多个广播都出现后再一次性上报。
     */
    private fun emitIfMatchCountSatisfied(bleConfig: BleConfig, deviceSn: String, bleDevice: BleDevice) {
        // 1. 单设备配置无需聚合，直接发给 Flutter。
        if (bleConfig.scan.matchCount < 2) {
            emitMatchDevices(deviceSn, listOf(bleDevice))
            return
        }

        // 2. 多设备配置按 SN 聚合同组设备，直到数量达到 matchCount。
        val matchDevices = synchronized(scanResultTemp) {
            scanResultTemp.filter { it.sn == bleDevice.sn }
        }
        if (matchDevices.size == bleConfig.scan.matchCount) {
            emitMatchDevices(deviceSn, matchDevices)
        }
    }

    /**
     * 按 snRule 从原始 scan record 中截取并清洗 SN。
     */
    private fun parseDataToObtainSn(bytes: ByteArray?, snRule: BleSnRule): String {
        // 1. 没有广播数据时无法解析。
        if (bytes == null) {
            return ""
        }

        // 2. 起始索引或最小长度不满足规则时直接失败。
        val startIndex = snRule.startSubIndex
        if (startIndex >= bytes.size || (snRule.byteLength > 0 && bytes.size < snRule.byteLength)) {
            return ""
        }

        // 3. byteLength 大于 0 时按配置边界截取，否则读到 scan record 尾部。
        var endIndex = bytes.size
        if (snRule.byteLength > 0 && endIndex > (snRule.byteLength - startIndex)) {
            endIndex = snRule.byteLength
        }

        // 4. UTF-8 转字符串后再执行 replaceRex 清洗控制字符或协议填充。
        val sn = String(bytes.copyOfRange(startIndex, endIndex), Charsets.UTF_8)
        return replaceControlCharacters(sn, snRule)
    }

    /**
     * 输出定向 R1 SN 广播排查日志。
     *
     * 这是一个受限诊断日志，只对历史问题设备名开启，避免普通扫描刷屏。
     */
    private fun logRingSnAdvertisementDebug(
        name: String,
        scanRecordBytes: ByteArray?,
        snRule: BleSnRule,
        parsedSn: String,
    ) {
        // 1. 只保留历史排障目标，避免所有设备都输出完整广播。
        if (name != "EVEN R1_1AF5A7") {
            return
        }

        // 2. 同时输出完整 scan record 和当前规则切片，便于判断 snRule 是否偏移。
        val slice = extractSnRuleSlice(scanRecordBytes, snRule)
        val sliceText = slice.toBleDebugText()
        sendLog(
            BleLoggerTag.d,
            "Start scan: R1 SN ADV debug, name=$name, " +
                "recordSize=${scanRecordBytes?.size ?: 0}, " +
                "snRule(start=${snRule.startSubIndex}, byteLength=${snRule.byteLength}), " +
                "parsedSn=$parsedSn, " +
                "currentSliceHex=${slice.toBleDebugHex()}, " +
                "currentSliceText=$sliceText, " +
                "scanRecordHex=${scanRecordBytes.toBleDebugHex()}",
        )
    }

    /**
     * 按 snRule 截取当前实际读取的字节片段。
     */
    private fun extractSnRuleSlice(bytes: ByteArray?, snRule: BleSnRule): ByteArray? {
        // 1. 没有数据时返回 null，日志中可区分“无数据”和“空切片”。
        if (bytes == null) {
            return null
        }

        // 2. 边界不满足规则时返回空数组，说明有数据但不能按当前规则截取。
        val startIndex = snRule.startSubIndex
        if (startIndex >= bytes.size || (snRule.byteLength > 0 && bytes.size < snRule.byteLength)) {
            return ByteArray(0)
        }

        // 3. 与正式 parser 使用相同的结束位置计算方式，保证诊断日志一致。
        var endIndex = bytes.size
        if (snRule.byteLength > 0 && endIndex > (snRule.byteLength - startIndex)) {
            endIndex = snRule.byteLength
        }
        if (endIndex <= startIndex) {
            return ByteArray(0)
        }
        return bytes.copyOfRange(startIndex, endIndex)
    }

    /**
     * 按正则清洗 SN 中的控制字符或协议填充。
     */
    private fun replaceControlCharacters(preSn: String, snRule: BleSnRule): String {
        // 1. 未配置 replaceRex 时保持原始解析结果。
        if (snRule.replaceRex.isEmpty()) {
            return preSn
        }

        // 2. 正则只作用于当前 SN，不影响扫描设备名。
        val pattern = Pattern.compile(snRule.replaceRex)
        val matcher = pattern.matcher(preSn)
        return matcher.replaceAll("")
    }

    /**
     * 将字节数组转成十六进制日志文本。
     */
    private fun ByteArray?.toBleDebugHex(): String {
        // 1. null/空数组分别输出不同文本，方便判断数据源状态。
        if (this == null) {
            return "null"
        }
        if (isEmpty()) {
            return ""
        }

        // 2. 每个字节以两位大写十六进制展示。
        return joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
    }

    /**
     * 将字节数组转成可读文本日志。
     */
    private fun ByteArray?.toBleDebugText(): String {
        // 1. null 需要保留为字面量，避免和空字符串混淆。
        if (this == null) {
            return "null"
        }

        // 2. 控制字符替换为点，避免日志输出不可见字符。
        return toString(Charsets.UTF_8)
            .map { char ->
                if (Character.isISOControl(char)) {
                    '.'
                } else {
                    char
                }
            }
            .joinToString("")
    }
}
