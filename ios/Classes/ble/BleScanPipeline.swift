//
//  BleScanPipeline.swift
//  flutter_ezw_ble
//
//  Owns CoreBluetooth advertisement parsing, scan-result caching, scan-then-connect
//  matching, and scan-result emission. BleManager delegates discovered peripherals
//  here so the manager no longer contains scan parsing policy.
//

import CoreBluetooth
import Foundation
import flutter_ezw_utils

/**
 * iOS 扫描解析与扫描后连接流程。
 *
 * 该扩展只处理 `didDiscover` 之后的扫描域逻辑：目标过滤、MAC/SN 解析、matchCount 聚合、
 * scan-then-connect 命中。它不拥有 CoreBluetooth manager，也不直接处理 GATT readiness。
 */
extension BleManager {
    /**
     * 处理 CoreBluetooth 扫描发现的外设。
     *
     * 主 manager 的 delegate 只负责转发到这里，避免 `BleManager.swift` 同时承担扫描解析和
     * 连接/GATT 状态机职责。
     */
    func handleDiscoveredPeripheral(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        // 1. 优先使用广播 local name。CoreBluetooth 的 peripheral.name 可能要到连接后才稳定，
        // 如果只看 peripheral.name，刚安装或未连接过的设备会被误判成“无名称”而搜索不到。
        guard let advertisedName = resolveAdvertisedName(
            peripheral: peripheral,
            advertisementData: advertisementData
        ) else {
            return
        }

        // 2. 如果当前存在 scan-then-connect 请求，优先让扫描结果尝试唤醒连接流程。
        // iOS 初次发现或冷启动恢复时 `peripheral.name` 可能为空，必须把广播名传进去参与匹配。
        guard startConnectWithoutLocalStorage(
            peripheral: peripheral,
            advertisedName: advertisedName,
            rssi: rssi.intValue
        ) else {
            return
        }

        // 3. 同一个 peripheral 在当前扫描窗口只处理一次，避免重复上报 scanResult。
        guard !scanResultTemp.contains(where: { info in
            info.0.uuid == peripheral.identifier.uuidString
        }) else {
            return
        }

        // 4. 按配置 nameFilters 匹配目标设备，插件本体不硬编码任何设备型号。
        guard let bleConfig = bleConfigs.first(where: { config in
            config.scan.nameFilters.first { filter in
                advertisedName.contains(filter)
            } != nil
        }) else {
            // 只对疑似目标设备输出 noConfig，避免把附近所有 BLE 广播都刷进 Flutter 日志。
            if shouldLogUnmatchedAdvertisedName(advertisedName) {
                logScanDropOnce(
                    key: "no-config-\(peripheral.identifier.uuidString)-\(advertisedName)",
                    message: "scan/debug drop noConfig name=\(advertisedName), uuid=\(peripheral.identifier.uuidString), configuredFilters=\(bleConfigs.flatMap { $0.scan.nameFilters })"
                )
            }
            return
        }

        // 5. 命中配置后先打一次发现日志。后续如果 MAC/SN/matchCount 没过，
        // 这条日志能证明 CoreBluetooth didDiscover 已经进来。
        let manufactureData = advertisementData["kCBAdvDataManufacturerData"] as? Data
        logScanDropOnce(
            key: "discover-\(peripheral.identifier.uuidString)-\(advertisedName)-\(bleConfig.name)",
            message: "scan/debug discovered name=\(advertisedName), uuid=\(peripheral.identifier.uuidString), config=\(bleConfig.name), rssi=\(rssi.intValue), mfrSize=\(manufactureData?.count ?? 0)"
        )

        // 6. 纯净模式只展示原始设备，不执行 MAC/SN 规则，便于排查广播内容。
        guard !scanPureModel else {
            emitPureScanResult(
                peripheral: peripheral,
                advertisedName: advertisedName,
                bleConfig: bleConfig,
                rssi: rssi.intValue
            )
            return
        }

        // 7. 普通模式先解析 MAC；没有 MAC 的广播需要继续等待下一次 advertisement。
        let deviceMac = parseDataToMac(manufactureData: manufactureData, macRule: bleConfig.scan.macRule)
        guard deviceMac.isNotEmpty else {
            logScanDropOnce(
                key: "mac-empty-\(peripheral.identifier.uuidString)-\(advertisedName)-\(bleConfig.name)",
                message: "scan/debug drop macEmpty name=\(advertisedName), uuid=\(peripheral.identifier.uuidString), config=\(bleConfig.name), mfrSize=\(manufactureData?.count ?? 0), macRule=\(bleConfig.scan.macRule.map { "\($0.startIndex)..<\($0.endIndex),reverse=\($0.isReverse)" } ?? "nil")"
            )
            return
        }

        // 8. 再解析 SN；SN 过滤失败时不向 Flutter 暴露该设备。
        guard let deviceSn = resolveDeviceSn(
            peripheralName: advertisedName,
            manufactureData: manufactureData,
            snRule: bleConfig.scan.snRule
        ) else {
            let parsedSn = parseDataToObtainSn(
                manufactureData: manufactureData,
                snRule: bleConfig.scan.snRule
            )
            logScanDropOnce(
                key: "sn-empty-\(peripheral.identifier.uuidString)-\(advertisedName)-\(bleConfig.name)",
                message: "scan/debug drop snRule name=\(advertisedName), uuid=\(peripheral.identifier.uuidString), config=\(bleConfig.name), mfrSize=\(manufactureData?.count ?? 0), parsedSn=\(parsedSn), snRule=\(bleConfig.scan.snRule.map { "start=\($0.startSubIndex),byteLength=\($0.byteLength),filters=\($0.filters)" } ?? "nil")"
            )
            return
        }

        // 9. 设备身份完整后，缓存并按 matchCount 决定是否聚合上报。
        emitMatchedScanResult(
            peripheral: peripheral,
            advertisedName: advertisedName,
            bleConfig: bleConfig,
            sn: deviceSn,
            mac: deviceMac,
            rssi: rssi.intValue
        )
    }

    /**
     * 输出一次性扫描诊断日志。
     *
     * iOS 扫描设置了 AllowDuplicates，目标设备可能每秒回调很多次。诊断日志必须按 key 去重，
     * 否则用户只会看到刷屏，反而难以判断第一处过滤断点。
     */
    private func logScanDropOnce(key: String, message: String) {
        // 1. 相同扫描断点只打印第一次，保留“发生过”的证据即可。
        guard BleScanDebugLog.shouldLog(key: key) else {
            return
        }

        // 2. 所有扫描诊断都使用 scan/debug 前缀，便于终端 grep。
        loggerD(msg: message)
    }

    /**
     * 判断未命中配置的广播是否值得输出日志。
     *
     * 搜索页可能处在公共环境，附近会有大量 BLE 广播；这里仅保留疑似 Even/G2/R1 设备，
     * 用于发现配置 nameFilters 写错或大小写不一致的问题。
     */
    private func shouldLogUnmatchedAdvertisedName(_ name: String) -> Bool {
        // 1. 大小写不敏感匹配常见产品关键词。
        let lowerName = name.lowercased()
        return lowerName.contains("even") ||
            lowerName.contains("g2") ||
            lowerName.contains("r1")
    }

    /**
     * 解析当前扫描回调里的稳定展示名。
     *
     * iOS 不保证 `CBPeripheral.name` 在扫描阶段可用；广告包里的
     * `CBAdvertisementDataLocalNameKey` 才是很多 BLE 外设首次被发现时的真实名称来源。
     */
    private func resolveAdvertisedName(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> String? {
        // 1. 优先读取广告 local name，让未连接过的设备也能被 nameFilters 命中。
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           localName.isNotEmpty {
            return localName
        }

        // 2. 广告包没有 local name 时，退回 CoreBluetooth 缓存名。
        if let peripheralName = peripheral.name,
           peripheralName.isNotEmpty {
            return peripheralName
        }

        // 3. 两处都没有名称时无法执行配置驱动的 nameFilters。
        return nil
    }

    /**
     * 发送纯净扫描模式结果。
     *
     * 纯净模式用于调试广播发现能力，因此使用随机 SN 避免和业务聚合规则混在一起。
     */
    private func emitPureScanResult(
        peripheral: CBPeripheral,
        advertisedName: String,
        bleConfig: BleConfig,
        rssi: Int
    ) {
        // 1. 随机 SN 只用于单次调试展示，不参与真实业务绑定。
        let pureSn = UUID().uuidString

        // 2. 构造最小 BleDevice 并写入扫描缓存，防止重复上报。
        let bleDevice = peripheral.toBleDevice(
            belongConfig: bleConfig.name,
            sn: pureSn,
            rssi: rssi,
            mac: "",
            advertisedName: advertisedName
        )
        scanResultTemp.append((bleDevice, peripheral))

        // 3. 纯净模式不做 matchCount 聚合，立即回传。
        sendMatchDevices(sn: pureSn, devices: [bleDevice])
    }

    /**
     * 根据 SN 规则解析并校验最终设备 SN。
     *
     * 返回 nil 表示该广播不满足当前配置的 SN 过滤规则，不应该展示给 Flutter。
     */
    private func resolveDeviceSn(
        peripheralName: String,
        manufactureData: Data?,
        snRule: BleSnRule?
    ) -> String? {
        // 1. 没有 SN 规则时，设备名就是默认 SN。
        guard let snRule = snRule else {
            return peripheralName
        }

        // 2. 有 SN 规则时优先使用广播解析值。
        let parsedSn = parseDataToObtainSn(manufactureData: manufactureData, snRule: snRule)
        logRingSnAdvertisementDebug(
            name: peripheralName,
            manufactureData: manufactureData,
            snRule: snRule,
            parsedSn: parsedSn
        )

        // 3. 解析值命中过滤器时使用解析值，否则保留设备名再走最终过滤。
        var deviceSn = peripheralName
        if parsedSn.isNotEmpty,
           (snRule.filters.isEmpty || snRule.filters.contains(where: { mark in
               parsedSn.contains(mark)
           })) {
            deviceSn = parsedSn
        }

        // 4. 最终 SN 为空或不包含目标标识时丢弃，避免未配对设备污染扫描结果。
        if deviceSn.isEmpty ||
            snRule.filters.isNotEmpty,
           !snRule.filters.contains(where: { mark in deviceSn.contains(mark) }) {
            logDroppedSnIfNeeded(peripheralName: peripheralName, parsedSn: parsedSn, finalSn: deviceSn, filters: snRule.filters)
            return nil
        }

        return deviceSn
    }

    /**
     * 在 SN 过滤丢弃关键设备时输出诊断日志。
     *
     * 仅对已知排障目标输出，避免普通扫描环境下日志过载。
     */
    private func logDroppedSnIfNeeded(peripheralName: String, parsedSn: String, finalSn: String, filters: [String]) {
        // 1. 这些名称是历史排障中需要看 SN 解析细节的目标。
        let shouldLog = peripheralName.contains("EVEN R1") ||
            peripheralName.contains("B210") ||
            peripheralName.contains("B290") ||
            peripheralName.contains("DfuTarg")

        // 2. 非排障目标静默丢弃，保持扫描日志可读。
        guard shouldLog else {
            return
        }
        loggerE(msg: "Start scan: drop by snRule, name=\(peripheralName), parsedSn=\(parsedSn), finalSn=\(finalSn), filters=\(filters)")
    }

    /**
     * 缓存并发送匹配后的扫描结果。
     *
     * matchCount 为 1 时立即上报；大于 1 时按 SN 聚合同一组设备后再上报。
     */
    private func emitMatchedScanResult(
        peripheral: CBPeripheral,
        advertisedName: String,
        bleConfig: BleConfig,
        sn: String,
        mac: String,
        rssi: Int
    ) {
        // 1. 构建业务扫描设备并写入缓存。
        let bleDevice = peripheral.toBleDevice(
            belongConfig: bleConfig.name,
            sn: sn,
            rssi: rssi,
            mac: mac,
            advertisedName: advertisedName
        )
        scanResultTemp.append((bleDevice, peripheral))

        // 2. 单设备配置立即发送。
        guard bleConfig.scan.matchCount > 1 else {
            sendMatchDevices(sn: sn, devices: [bleDevice])
            return
        }

        // 3. 多设备配置按同 SN 聚合，达到 matchCount 后再发送给 Flutter。
        let matchDevices = scanResultTemp.filter { info in
            info.0.sn == bleDevice.sn
        }.map { info in
            info.0
        }
        guard matchDevices.count == bleConfig.scan.matchCount else {
            logScanDropOnce(
                key: "partial-\(bleConfig.name)-\(sn)-\(matchDevices.count)",
                message: "scan/debug partialMatch config=\(bleConfig.name), sn=\(sn), count=\(matchDevices.count)/\(bleConfig.scan.matchCount), devices=\(matchDevices.map { "\($0.name)|\($0.uuid)|\($0.mac)" })"
            )
            return
        }
        loggerD(msg: "scan/debug matchReady config=\(bleConfig.name), sn=\(sn), count=\(matchDevices.count)/\(bleConfig.scan.matchCount)")
        sendMatchDevices(sn: sn, devices: matchDevices)
    }

    /**
     * 从广播 manufacturer data 解析 MAC 地址。
     *
     * iOS 扫描拿不到真实 MAC，只能按业务广播规则截取并可选反转字节序。
     */
    private func parseDataToMac(manufactureData: Data?, macRule: BleMacRule?) -> String {
        // 1. 没有制造商数据或 MAC 规则时，无法解析 MAC。
        guard var manufactureData = manufactureData, let macRule = macRule else {
            return ""
        }

        // 2. 截取范围需要保护越界，避免异常广播导致崩溃。
        var startIndex = macRule.startIndex
        if startIndex > manufactureData.count {
            startIndex = 0
        }
        var endIndex = macRule.endIndex
        if manufactureData.count < macRule.endIndex {
            endIndex = manufactureData.endIndex
        }
        manufactureData = manufactureData.subdata(in: startIndex..<endIndex)

        // 3. 根据配置决定是否反转字节序，再拼成冒号分隔 MAC。
        var hexList = manufactureData.map {
            String(format: "%02X", $0)
        }
        if macRule.isReverse {
            hexList = hexList.reversed()
        }
        return hexList.joined(separator: ":")
    }

    /**
     * 从 manufacturer data 解析 SN。
     *
     * 该函数只负责截取和 UTF-8 解码，过滤规则由 `resolveDeviceSn` 处理。
     */
    private func parseDataToObtainSn(manufactureData: Data?, snRule: BleSnRule?) -> String {
        // 1. 缺少数据或规则时返回空字符串，让上层按规则失败处理。
        guard var manufactureData = manufactureData, let snRule = snRule else {
            return ""
        }

        // 2. 校验起点和最小长度，越界广播不能继续截取。
        var startIndex = snRule.startSubIndex
        if startIndex >= manufactureData.count ||
            (snRule.byteLength > 0 && manufactureData.count < snRule.byteLength) {
            return ""
        }

        // 3. byteLength 表示从 0 开始的截取终点，保持旧实现语义。
        var endIndex = manufactureData.endIndex
        if snRule.byteLength > 0, manufactureData.count > snRule.byteLength {
            endIndex = snRule.byteLength
        }
        manufactureData = manufactureData.subdata(in: startIndex..<endIndex)

        // 4. 最后按配置正则清理控制字符。
        let sn = String(data: manufactureData, encoding: .utf8) ?? ""
        return replaceControlCharacters(in: sn, snRule: snRule)
    }

    /**
     * 输出定向 SN 广播解析日志。
     *
     * 该日志服务历史 R1 广播排障，不改变扫描匹配结果。
     */
    private func logRingSnAdvertisementDebug(
        name: String,
        manufactureData: Data?,
        snRule: BleSnRule,
        parsedSn: String
    ) {
        // 1. 只对指定排障设备输出，避免每条广播都打印大块 hex。
        guard name == "EVEN R1_1AF5A7" else {
            return
        }
        let slice = extractSnRuleSlice(data: manufactureData, snRule: snRule)
        let sliceText = slice.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let parts = [
            "Start scan: R1 SN ADV debug, name=\(name)",
            "manufactureSize=\(manufactureData?.count ?? 0)",
            "snRule(start=\(snRule.startSubIndex), byteLength=\(snRule.byteLength))",
            "parsedSn=\(parsedSn)",
            "currentSliceHex=\(slice.toBleDebugHex())",
            "currentSliceText=\(sliceText)",
            "manufactureDataHex=\(manufactureData.toBleDebugHex())"
        ]
        loggerD(msg: parts.joined(separator: ", "))
    }

    /**
     * 按 SN 规则截取当前广播片段。
     *
     * 只用于调试日志，返回空 Data 表示规则越界或无有效片段。
     */
    private func extractSnRuleSlice(data: Data?, snRule: BleSnRule) -> Data? {
        // 1. 无广播数据时没有可截取内容。
        guard let data = data else {
            return nil
        }

        // 2. 起点或长度越界时返回空片段，保留诊断信息。
        let startIndex = snRule.startSubIndex
        if startIndex >= data.count ||
            (snRule.byteLength > 0 && data.count < snRule.byteLength) {
            return Data()
        }

        // 3. 终点按旧 parser 语义计算，并再次保护反向范围。
        var endIndex = data.endIndex
        if snRule.byteLength > 0, data.count > snRule.byteLength {
            endIndex = snRule.byteLength
        }
        if endIndex <= startIndex {
            return Data()
        }
        return data.subdata(in: startIndex..<endIndex)
    }

    /**
     * 按配置正则清理 SN 控制字符。
     *
     * 正则无效时保留原始 SN，避免配置错误导致扫描流程崩溃。
     */
    private func replaceControlCharacters(in preSn: String, snRule: BleSnRule?) -> String {
        // 1. 没有清理规则时直接返回原始 SN。
        guard let snRule = snRule, snRule.replaceRex.isNotEmpty else {
            return preSn
        }

        // 2. 正则编译失败时不丢弃设备，只保留原始 SN。
        guard let regex = try? NSRegularExpression(pattern: snRule.replaceRex, options: []) else {
            return preSn
        }

        // 3. 用空字符串替换匹配到的控制字符。
        let nsString = preSn as NSString
        return regex.stringByReplacingMatches(
            in: preSn,
            options: [],
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: ""
        )
    }

    /**
     * 本地无外设缓存时，通过扫描命中继续连接。
     *
     * 该函数服务 scan-then-connect：主动连接时如果 retrieve 不到 peripheral，就暂存请求并扫描；
     * 扫描命中后从这里补全 uuid、启动连接超时并进入 GATT 连接。
     */
    private func startConnectWithoutLocalStorage(peripheral: CBPeripheral, advertisedName: String, rssi: Int) -> Bool {
        // 1. 没有等待扫描命中的连接请求时，扫描结果继续走普通展示流程。
        guard startConnectInfos.isNotEmpty else {
            return true
        }

        // 2. 遍历当前挂起请求，命中后立即发起 CoreBluetooth connect。
        for connectDevice in startConnectInfos {
            guard let bleConfig = connectDevice.bleConfig else {
                failScanConnectWithoutConfig(connectDevice)
                return false
            }

            var canRemove = false
            if isScanConnectExpired(connectDevice, bleConfig: bleConfig) {
                handleConnectState(uuid: connectDevice.uuid, name: connectDevice.name, state: .noDeviceFound, tag: "scan timestamp fallback")
                canRemove = true
            } else if connectDevice.uuid == peripheral.identifier.uuidString || connectDevice.name == advertisedName || connectDevice.name == (peripheral.name ?? "") {
                connectFoundPeripheral(
                    peripheral,
                    advertisedName: advertisedName,
                    rssi: rssi,
                    request: connectDevice,
                    bleConfig: bleConfig
                )
                canRemove = true
            }

            // 3. 命中或超时的请求需要从等待队列移除；队列为空时停止扫描。
            if canRemove {
                startConnectInfos.removeAll { info in
                    info.uuid == connectDevice.uuid || info.name == connectDevice.name
                }
                if startConnectInfos.isEmpty {
                    stopScan()
                }
            }
        }
        return false
    }

    /**
     * 处理 scan-then-connect 请求缺少配置的失败路径。
     *
     * 配置缺失是终态错误，必须取消扫描 timeout 并通知 Dart。
     */
    private func failScanConnectWithoutConfig(_ request: BleEasyConnect) {
        // 1. 取消该请求的扫描超时器。
        cancelScanConnectTimeout(uuid: request.uuid, name: request.name)

        // 2. 从等待队列移除，避免后续扫描命中继续连接。
        startConnectInfos.removeAll { info in
            info.uuid == request.uuid || info.name == request.name
        }
        if startConnectInfos.isEmpty {
            stopScan()
        }

        // 3. 上报配置缺失终态。
        handleConnectState(uuid: request.uuid, name: request.name, state: .noBleConfigFound)
        loggerE(msg: "centralManager - search: \(request.uuid)-\(request.name), no config found")
    }

    /**
     * 判断 scan-then-connect 请求是否已超时。
     *
     * 这是扫描等待阶段的超时，不等同于 GATT readiness 超时。
     */
    private func isScanConnectExpired(_ request: BleEasyConnect, bleConfig: BleConfig) -> Bool {
        // 1. 没有开始时间时不按时间戳超时，由显式 timer 兜底。
        guard let startTime = request.time else {
            return false
        }

        // 2. connectTimeout 使用毫秒配置，Date 差值是秒。
        let expired = Date().timeIntervalSince1970 - startTime > bleConfig.connectTimeout / 1000
        if expired {
            loggerD(msg: "centralManager - search: \(request.uuid)-\(request.name), scan timestamp fallback")
        }
        return expired
    }

    /**
     * 扫描命中待连接外设后继续 CoreBluetooth 连接。
     *
     * 该函数补全 UUID、写入连接缓存、启动 GATT 超时并调用统一 connectPeripheral。
     */
    private func connectFoundPeripheral(
        _ peripheral: CBPeripheral,
        advertisedName: String,
        rssi: Int,
        request: BleEasyConnect,
        bleConfig: BleConfig
    ) {
        // 1. 扫描命中后取消扫描阶段 timeout，后续由 GATT 连接 timeout 接管。
        // 广播名比 `peripheral.name` 更早可用；这里用它回写 active request，
        // 否则 CoreBluetooth identifier 已刷新但 name 为空时，Dart 侧会继续等旧 UUID。
        let peripheralName = advertisedName.isNotEmpty ? advertisedName : (peripheral.name ?? request.name)
        cancelScanConnectTimeout(uuid: request.uuid, name: request.name)

        // 2. 启动 GATT 连接阶段 timeout。
        startConnectingCountdown(
            currentConfig: bleConfig,
            uuid: peripheral.identifier.uuidString,
            name: peripheralName,
            afterUpgrade: request.afterUpgrade
        )

        // 3. 如果还没有缓存该 peripheral，先写入 connectedDevices 供回调反查配置。
        if !connectedDevices.contains(where: { device in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString || device.peripheral.name == peripheralName
        }) {
            connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: peripheral))
        }

        // 4. 原请求可能没有 UUID，扫描命中后必须补全，后续 didConnect/服务发现才能匹配。
        updateActiveConnectRequestUuid(uuid: peripheral.identifier.uuidString, name: peripheralName)

        // 5. 统一进入连接中状态，并复用 connectPeripheral 处理 auto reconnect options。
        handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheralName, state: .connecting, tag: "from search device")
        connectPeripheral(
            peripheral,
            autoReconnect: isAutoReconnectAttempt(uuid: peripheral.identifier.uuidString, name: peripheralName)
        )
        loggerD(msg: "centralManager - search: \(request.uuid)-\(request.name), device has been found, start connecting, after upgrade \(request.afterUpgrade)")
    }

    /**
     * 发送匹配设备到 Flutter。
     *
     * Flutter 侧统一接收 BleMatchDevice JSON，因此单设备和多设备聚合都走这里。
     */
    private func sendMatchDevices(sn: String, devices: [BleDevice]) {
        // 1. 先构造业务聚合模型。
        let matchDevice = BleMatchDevice(sn: sn, devices: devices)
        do {
            // 2. JSON 序列化失败时不能发送半截数据。
            guard let jsonDic = try matchDevice.toJsonString() else {
                return
            }

            // 3. 通过 scanResult EventChannel 推给 Flutter。
            BleEC.scanResult.emit(jsonDic)
            loggerD(msg: "centralManager - sendMatchDevices: \(jsonDic)")
        } catch {
            loggerE(msg: "centralManager - sendMatchDevices: error = \(error)")
        }
    }
}

/**
 * 扫描调试用 Data hex 转换。
 *
 * 该扩展只在本文件可见，避免把调试格式扩散成公共 API。
 */
private extension Optional where Wrapped == Data {
    /**
     * 将可选 Data 转成空格分隔十六进制字符串。
     *
     * nil 输出 "null"，空 Data 输出空字符串，便于日志区分两类情况。
     */
    func toBleDebugHex() -> String {
        // 1. nil 表示没有广播字段。
        guard let data = self else {
            return "null"
        }

        // 2. 空数据表示字段存在但长度为 0。
        guard !data.isEmpty else {
            return ""
        }

        // 3. 每个字节转成两位大写 hex，保持与 Android 调试日志一致。
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/**
 * iOS 扫描诊断日志去重器。
 *
 * AllowDuplicates 扫描会高频回调相同外设；用进程内 Set 记录已经输出过的断点，避免日志刷屏。
 */
private enum BleScanDebugLog {
    /// 本次进程内已经输出过的扫描断点 key。
    private static var emittedKeys: Set<String> = []

    /**
     * 判断某个扫描诊断 key 是否应该输出。
     *
     * 返回 true 时会同步记录该 key；调用方随后输出对应日志。
     */
    static func shouldLog(key: String) -> Bool {
        // 1. 已输出过的断点不再重复打印。
        guard !emittedKeys.contains(key) else {
            return false
        }

        // 2. 新断点立即记录，保证后续重复广播被抑制。
        emittedKeys.insert(key)
        return true
    }
}
