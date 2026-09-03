//
//  BleConnectCoordinator.swift
//  flutter_ezw_ble
//
//  Owns the iOS foreground connect request flow. The coordinator resolves an
//  existing peripheral, scan cache, system-connected peripheral, or scan-needed
//  route, then hands every successful physical connection to the shared GATT
//  readiness pipeline in BleManager.
//

import CoreBluetooth
import Foundation

/**
 *  iOS 主动连接协调器。
 *
 *  保持为 BleManager extension 是为了复用现有扫描缓存、CoreBluetooth delegate 和 GATT pipeline；
 *  拆出文件后，BleManager 主文件只保留入口/状态/回调胶水，连接路由逻辑集中在这里。
 */
extension BleManager {
    /**
     *  发起一次明确的连接请求。
     *
     *  该方法只表达前台/业务主动 connect，不负责长期重连调度；自动回连会复用此入口，
     *  但是否 arm 自动回连仍由 Dart 业务认证成功后的 deviceConnected 决定。
     */
    func connect(easyConnect: BleEasyConnect) {
        // 1、校验蓝牙能力和配置，空身份请求在进入异步流程前失败闭环。
        // 默认功能检查失败时必须显式上报 bleError，不能静默丢弃连接请求。
        guard checkIsFunctionCanBeCalled() else {
            loggerE(msg: "connect-flow: \(easyConnect.uuid) ble error")
            handleConnectState(uuid: easyConnect.uuid, name: easyConnect.name, state: .bleError)
            return
        }
        // 2、清理旧预连接/升级标记，避免上一次认证状态污染本次连接。
        preConnectedDevices.remove(easyConnect.uuid)
        if !easyConnect.afterUpgrade {
            // 非 OTA 恢复连接不能继续占用升级态，否则普通指令会被升级保护拒绝。
            upgradeStateRegistry.consume(easyConnect.uuid)
        }
        guard let bleConfig = findCurrentBleConfig(
            belongConfig: easyConnect.belongConfig,
            uuid: easyConnect.uuid,
            name: easyConnect.name
        ) else {
            loggerE(msg: "connect-flow: \(easyConnect.uuid) no bleConfig find")
            handleConnectState(uuid: easyConnect.uuid, name: easyConnect.name, state: .noBleConfigFound)
            return
        }
        let commonPs = bleConfig.privateServices.first { $0.type == 0 }
        guard easyConnect.uuid.isNotEmpty || easyConnect.name.isNotEmpty, commonPs != nil else {
            loggerE(msg: "connect-flow: \(easyConnect.uuid) can not find")
            handleConnectState(uuid: easyConnect.uuid, name: easyConnect.name, state: .emptyUuid)
            return
        }

        // 3、手动点击优先复用已存在的 autoReconnect pending session，只提升本轮 source/等待优先级；
        // 不 cancel CoreBluetooth 后重开同一外设，避免旧终态回调与新 generation 交叉。
        if easyConnect.uuid.isNotEmpty,
           let current = currentConnectionAdmission(uuid: easyConnect.uuid) {
            if let session = peripheralConnectionSessions[current.sessionId],
               reconnectTasks[reconnectKey(uuid: easyConnect.uuid)] != nil,
               replaceStalePendingManualAttemptIfNeeded(session.peripheral) {
                // 此处只处理已有长期 autoReconnect owner 的陈旧 pending。replacement
                // 已建立 cancellation barrier；beginReconnectAttempt 会注册新 generation，
                // 新 connect 必须等旧 CoreBluetooth 终态或 barrier watchdog 后才发出。
                loggerD(msg: "connect-flow: \(easyConnect.uuid)-\(easyConnect.name), replace stale pending autoReconnect attempt")
                beginReconnectAttempt(uuid: easyConnect.uuid)
                return
            }
            if promotePendingAttempt(uuid: easyConnect.uuid) {
                loggerD(msg: "connect-flow: \(easyConnect.uuid)-\(easyConnect.name), reuse and promote pending autoReconnect attempt")
                return
            }
        }

        // 4、空 UUID 使用临时 session 标识，稳定 peripheral identity 仍由后续发现结果补齐。
        let newUuid = easyConnect.uuid.isEmpty ? "temp-\(UUID().uuidString)" : easyConnect.uuid
        var newEasyConnect = BleEasyConnect(
            configName: bleConfig.name,
            uuid: newUuid,
            name: easyConnect.name,
            afterUpgrade: easyConnect.afterUpgrade,
            directConnect: easyConnect.directConnect,
            time: Date().timeIntervalSince1970,
        )
        newEasyConnect.bleConfig = bleConfig
        // 5、提交前台请求；串行顺序由 Dart/Gate 决定，原生只保证回调可追踪和取消。
        upsertActiveConnectRequest(newEasyConnect)
        loggerD(msg: BleConnectRequestLogContext(
            uuid: newEasyConnect.uuid,
            name: newEasyConnect.name,
            configName: bleConfig.name,
            directConnect: newEasyConnect.directConnect,
            afterUpgrade: newEasyConnect.afterUpgrade,
            activeRequests: activeConnectRequests.count,
            connectedDevices: connectedDevices.count,
            scanCache: scanResultTemp.count
        ).message)

        if !easyConnect.directConnect {
            // 前台连接需要避免离线/屏蔽箱设备复用旧扫描缓存造成 blind GATT timeout。
            purgeStaleScanCache(uuid: easyConnect.uuid, name: easyConnect.name)
        }

        var tag = "start connect: "
        var oldPeripheral: CBPeripheral?
        // 仅 scanResultTemp 命中时才要求本轮扫描可见；系统/retrieve 路径允许直接进入 CoreBluetooth connect。
        var requireScanVisibility = false

        if let index = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == easyConnect.uuid || device.peripheral.name == easyConnect.name
        }) {
            tag += "from connected device list"
            var device = connectedDevices[index]
            let id = device.peripheral.identifier
            let list = retrievePeripheralsWhenAppActive(
                withIdentifiers: [id],
                context: "foreground connected-device cache"
            )
            oldPeripheral = list.first ?? device.peripheral
            oldPeripheral?.delegate = self
            device.peripheral = oldPeripheral!
            connectedDevices[index] = device

            // iOS ANCS/system-connected 设备可能已经被系统连接并停止广播，扫描不可见不能等价为 noDevice。
            let cachedServiceUUIDs = bleConfig.privateServices.map { $0.serviceUUID }
            let systemConnected = oldPeripheral?.state == .connected
                || findPeripheralFromConnected(uuid: easyConnect.uuid, name: easyConnect.name, serviceUUIDs: cachedServiceUUIDs) != nil
            if systemConnected {
                loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(easyConnect.name), cached device is system-connected (ANCS), skip scan, connect directly")
            }
            requireScanVisibility = !easyConnect.directConnect && !systemConnected && oldPeripheral?.state != .connected
            if device.isConnected && device.isBleFlowCompleted {
                removeActiveConnectRequest(uuid: newEasyConnect.uuid, name: newEasyConnect.name)
                if let peripheral = oldPeripheral {
                    handleAlreadyConnected(peripheral: peripheral, bleConfig: bleConfig, deviceName: easyConnect.name, tag: tag)
                }
                loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), already connected, resync flow, \(tag)")
                return
            } else if device.isConnected {
                tag += ", resume incomplete connected flow"
            }

            // 异常断连后的首次重连先扫描刷新 CoreBluetooth 缓存；系统已连接设备不广播，必须跳过扫描刷新。
            if device.needsScanBeforeReconnect && !easyConnect.directConnect && !systemConnected {
                device.needsScanBeforeReconnect = false
                connectedDevices[index] = device
                handleConnectState(uuid: newEasyConnect.uuid, name: easyConnect.name, state: .connecting)
                startScan()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    guard let self = self else { return }
                    self.stopScan()
                    // 扫描期间可能已超时、取消或蓝牙关闭，请求已清空则不再重连。
                    guard self.findActiveConnectRequest(uuid: newEasyConnect.uuid, name: newEasyConnect.name) != nil else {
                        self.loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), scan finished but request no longer active, skip reconnect")
                        return
                    }
                    self.connect(easyConnect: easyConnect)
                }
                loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), scan 10s before reconnect to refresh CoreBT cache")
                return
            } else if device.needsScanBeforeReconnect {
                // directConnect 或系统已连接路径无需扫描刷新，清掉标记后继续直连。
                device.needsScanBeforeReconnect = false
                connectedDevices[index] = device
            }
            if device.isBleFlowCompleted {
                // 新连接 session 必须重置上一轮 BLE 流程完成标记，避免跨会话复用 connectFinish。
                device.isBleFlowCompleted = false
                connectedDevices[index] = device
            }
        } else if let temp = scanResultTemp.first(where: { info in
            return info.0.uuid == easyConnect.uuid || info.1.name == easyConnect.name
        }) {
            tag += "from scan result temp"
            oldPeripheral = temp.1
            requireScanVisibility = !easyConnect.directConnect
        } else if let device = findPeripheralFromConnected(
            uuid: easyConnect.uuid,
            name: easyConnect.name,
            serviceUUIDs: bleConfig.privateServices.map { $0.serviceUUID }
        ) {
            tag += "from bluetooth setting"
            oldPeripheral = device
            connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: device))
        }

        if oldPeripheral == nil, !easyConnect.uuid.isEmpty,
           let cbUuid = UUID(uuidString: easyConnect.uuid),
           let peripheral = retrievePeripheralsWhenAppActive(
               withIdentifiers: [cbUuid],
               context: "foreground connect by UUID"
           ).first {
            // retrievePeripherals 修复系统已连接但不广播的 ANCS 场景，避免 scan-first 永远扫不到。
            if peripheral.state == .connected {
                tag += "from retrievePeripherals (system-connected)"
                oldPeripheral = peripheral
                requireScanVisibility = false
            } else if easyConnect.directConnect {
                tag += "from retrievePeripherals cache"
                oldPeripheral = peripheral
            }
        }

        let autoReconnectAttempt = isAutoReconnectAttempt(
            uuid: newEasyConnect.uuid,
            name: newEasyConnect.name
        )

        guard let oldPeripheral = oldPeripheral else {
            if easyConnect.directConnect {
                if autoReconnectAttempt {
                    // autoReconnect 不再用显式扫描兜底。系统回连依赖 CoreBluetooth
                    // pending connect；没有 peripheral cache 时交给
                    // 回连调度器继续退避，而不是启动前台 scan-then-connect。
                    removeActiveConnectRequest(uuid: newEasyConnect.uuid, name: newEasyConnect.name)
                    handleConnectState(uuid: newEasyConnect.uuid, name: easyConnect.name, state: .noDeviceFound)
                    loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), autoReconnect directConnect: no peripheral cache, skip scan")
                    return
                }
                if !easyConnect.name.isEmpty {
                    // directConnect 优先缓存，但有稳定 name 时仍允许扫描兜底，避免误报 noDeviceFound。
                    tag += "directConnect no cache, fallback scan by name"
                    handleConnectState(uuid: newEasyConnect.uuid, name: easyConnect.name, state: .connecting)
                    startConnectInfos.append(newEasyConnect)
                    startScanConnectTimeout(currentConfig: bleConfig, uuid: newEasyConnect.uuid, name: newEasyConnect.name, afterUpgrade: easyConnect.afterUpgrade)
                    startScan()
                    loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), \(tag)")
                    return
                }
                // 没有 peripheral 缓存也没有稳定 name 时，directConnect 才能明确 fast-fail。
                removeActiveConnectRequest(uuid: newEasyConnect.uuid, name: newEasyConnect.name)
                handleConnectState(uuid: newEasyConnect.uuid, name: easyConnect.name, state: .noDeviceFound)
                loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), directConnect: no peripheral in CoreBluetooth cache and no name fallback")
                return
            }
            tag += "no local device found, start scan device"
            handleConnectState(uuid: newEasyConnect.uuid, name: easyConnect.name, state: .connecting)
            startConnectInfos.append(newEasyConnect)
            startScanConnectTimeout(currentConfig: bleConfig, uuid: newEasyConnect.uuid, name: newEasyConnect.name, afterUpgrade: easyConnect.afterUpgrade)
            startScan()
            loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), \(tag)")
            return
        }

        if requireScanVisibility && !isTargetVisibleInScan(uuid: easyConnect.uuid, name: easyConnect.name) {
            // scanResultTemp 和断开态缓存必须重新扫描确认可见；系统已连接/retrieve 路径不走这里。
            tag += ", target not visible in current scan, start scan device"
            handleConnectState(uuid: newEasyConnect.uuid, name: easyConnect.name, state: .connecting)
            startConnectInfos.append(newEasyConnect)
            startScanConnectTimeout(currentConfig: bleConfig, uuid: newEasyConnect.uuid, name: newEasyConnect.name, afterUpgrade: easyConnect.afterUpgrade)
            startScan()
            loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), \(tag)")
            return
        }

        tag += ", afterUpdate: \(newEasyConnect.afterUpgrade)"
        loggerD(msg: "connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), \(tag)")
        if !connectedDevices.contains(where: { $0.peripheral.identifier == oldPeripheral.identifier }) {
            // 先写入 in-flight 缓存，用户取消时才能找到 peripheral 并 cancelPeripheralConnection。
            connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: oldPeripheral))
        }
        oldPeripheral.delegate = self
        // 前台连接也先注册 Gate session；排队期间不起 pipeline timeout。
        if currentConnectionAdmission(uuid: oldPeripheral.identifier.uuidString) == nil {
            _ = registerConnectionAttempt(
                peripheral: oldPeripheral,
                config: bleConfig,
                deviceName: newEasyConnect.name,
                afterUpgrade: newEasyConnect.afterUpgrade,
                source: .foreground
            )
        }
        connectPeripheralAfterCancellationBarrier(oldPeripheral, autoReconnect: false)
        handleConnectState(
            uuid: oldPeripheral.identifier.uuidString,
            name: easyConnect.name,
            state: .connecting,
            source: .foreground
        )
    }
}
