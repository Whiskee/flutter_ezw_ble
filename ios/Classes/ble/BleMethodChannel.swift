//
//  BleMethodChannel.swift
//  flutter_ezw_ble
//
//  Owns iOS MethodChannel method dispatch. Keeping this separate from
//  BleChannel.swift makes the event-stream plumbing and command dispatch
//  independently readable.
//

import Flutter
import UIKit

/// MethodChannel command names received from Dart.
enum BleMC: String {
    case getPlatformVersion
    /// Query current CoreBluetooth state.
    case bleState
    /// Replace the native BLE configuration table.
    case initConfigs
    /// Start scan with optional pure scan mode.
    case startScan
    /// Stop active scan unless a scan-then-connect request is pending.
    case stopScan
    /// Check whether CoreBluetooth already owns a connected peripheral.
    case isSystemConnectedPeripheral
    /// Start one foreground connect request.
    case connectDevice
    /// Disconnect or cancel an in-flight connect request.
    case disconnectDevice
    /// Atomically revoke an exact logical device's reconnect owners and runtime.
    case cancelAutoReconnectTargets
    /// Android-only business connection liveness reconciliation; iOS is an explicit no-op.
    case reconcileBusinessConnections
    /// OTA reboot teardown: disconnect physical transport without revoking reconnect intent.
    case disconnectForOtaReboot
    /// Mark business-layer auth as about to complete.
    case devicePreConnected
    /// Mark business-layer auth as complete and arm auto reconnect.
    case deviceConnected
    /// Install an exact business-auth lease for the current GATT attempt.
    case prepareBusinessConnection
    /// Commit business connected after exact lease and GATT readiness checks.
    case commitBusinessConnection
    /// Abort only the exact business-auth lease.
    case abortBusinessConnection
    /// 仅补种 native 长期回连意图。
    case armAutoReconnectTargets
    /// 立即建立/复用所有目标的 CoreBluetooth pending connect。
    case activateAutoReconnectTargets
    /// 辅助扫描可见性提示；iOS 仅对 exact 陈旧 pending owner 做一次受控恢复。
    case notifyAutoReconnectTargetVisible
    /// Send one command and wait for the platform write path.
    case sendCmd
    /// Send without waiting; OTA uses the no-response backpressure queue.
    case sendCmdNoWait
    /// Mark a device as entering OTA mode.
    case enterUpgradeState
    /// Mark a device as leaving OTA mode.
    case quiteUpgradeState
    /// Enable/disable process-local native connection Trace.
    case setConnectionTraceEnabled
    /// Open system Bluetooth settings.
    case openBleSettings
    /// Open this app's settings page.
    case openAppSettings
    /// Clear persisted connect identity.
    case cleanConnectCache
    /// Drain native reconnect events buffered before Dart listeners.
    case drainAutoReconnectEvents
    /// Reset native BLE state.
    case resetBle
    /// Unknown method fallback.
    case unknown

    /**
     *  Dispatches one Dart MethodChannel call to the native BLE manager.
     *
     *  Method parsing intentionally stays thin: JSON/default normalization lives here,
     *  while BLE behavior remains in BleManager or its coordinators.
     */
    func handle(arguments: Any?, result: @escaping FlutterResult) {
        switch self {
        case .getPlatformVersion:
            result("iOS " + UIDevice.current.systemVersion)
            return
        case .bleState:
            result(BleManager.shared.currentBleState)
            return
        case .initConfigs:
            let jsonArray: Array<[String: Any]> = arguments as? Array<[String: Any]> ?? []
            let configs: Array<BleConfig?> = jsonArray
                .map { jsonData in
                    jsonData.decodeTo()
                }
                .filter { $0 != nil }
            BleEC.logger.emit("[d]-BleChannel::initConfigs received=\(jsonArray.count), decoded=\(configs.count)")
            // 配置本身必须先同步写入 native，再返回 Dart；否则 Dart await 后立刻
            // startScan/connect 时，iOS 仍可能处于空配置。BleManager.initConfigs 内部
            // 已经把 reconnect 重放 defer 到下一轮主队列，所以这里不会阻塞首帧。
            BleManager.shared.initConfigs(configs: configs.map { $0! })
            result(nil)
            return
        case .startScan:
            let jsonData: [String: Any] = arguments as? [String: Any] ?? [:]
            let turnOnPureModel = jsonData["turnOnPureModel"] as? Bool ?? false
            BleManager.shared.startScan(pureModel: turnOnPureModel)
            break
        case .stopScan:
            BleManager.shared.stopScan()
            break
        case .isSystemConnectedPeripheral:
            let jsonData: [String: Any] = arguments as? [String: Any] ?? [:]
            let belongConfig: String = jsonData["belongConfig"] as? String ?? ""
            let uuid: String = jsonData["uuid"] as? String ?? ""
            let name: String = jsonData["name"] as? String ?? ""
            result(BleManager.shared.isSystemConnectedPeripheral(
                belongConfig: belongConfig,
                uuid: uuid,
                name: name
            ))
            return
        case .connectDevice:
            var jsonData: [String: Any] = arguments as? [String: Any] ?? [:]
            // Dart older versions may omit nullable flags. Normalize them before decoding
            // so Swift Codable never sees NSNull for Bool fields.
            jsonData["afterUpgrade"] = jsonData["afterUpgrade"] as? Bool ?? false
            jsonData["directConnect"] = jsonData["directConnect"] as? Bool ?? false
            BleEC.logger.emit("[d]-BleChannel::connectDevice args uuid=\(jsonData["uuid"] as? String ?? ""), name=\(jsonData["name"] as? String ?? ""), sn=\(jsonData["sn"] as? String ?? ""), config=\(jsonData["belongConfig"] as? String ?? ""), afterUpgrade=\(jsonData["afterUpgrade"] as? Bool ?? false), directConnect=\(jsonData["directConnect"] as? Bool ?? false)")
            if let easyConnect: BleEasyConnect = jsonData.decodeTo() {
                BleManager.shared.connect(easyConnect: easyConnect)
            } else {
                BleEC.logger.emit("[e]-BleChannel::connectDevice decode failed: \(jsonData)")
                // 参数解码失败时必须让 Dart Future 失败；仅写日志会让 UI 等待永远不会
                // 到来的 connectStatus 终态。
                result(FlutterError(
                    code: "INVALID_CONNECT_ARGUMENTS",
                    message: "connectDevice arguments are malformed",
                    details: jsonData
                ))
                return
            }
            break
        case .deviceConnected:
            let uuid = arguments as? String ?? ""
            BleManager.shared.setConnected(uuid: uuid)
            break
        case .prepareBusinessConnection:
            let data = arguments as? [String: Any] ?? [:]
            result(BleManager.shared.prepareBusinessConnection(
                BleBusinessConnectionAttempt(data: data)
            ).rawValue)
            return
        case .commitBusinessConnection:
            let data = arguments as? [String: Any] ?? [:]
            result(BleManager.shared.commitBusinessConnection(
                BleBusinessConnectionAttempt(data: data)
            ).rawValue)
            return
        case .abortBusinessConnection:
            let data = arguments as? [String: Any] ?? [:]
            result(BleManager.shared.abortBusinessConnection(
                BleBusinessConnectionAttempt(data: data)
            ))
            return
        case .devicePreConnected:
            let uuid = arguments as? String ?? ""
            BleManager.shared.setPreConnected(uuid: uuid)
            break
        case .armAutoReconnectTargets:
            let targets = (arguments as? [[String: Any]] ?? []).compactMap { data -> BleReconnectTarget? in
                guard let belongConfig = data["belongConfig"] as? String,
                      let uuid = data["uuid"] as? String,
                      !belongConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return BleReconnectTarget(
                    belongConfig: belongConfig,
                    uuid: uuid,
                    name: data["name"] as? String ?? ""
                )
            }
            BleManager.shared.armAutoReconnectTargets(targets)
            break
        case .activateAutoReconnectTargets:
            let data = arguments as? [String: Any] ?? [:]
            let targets = (data["devices"] as? [[String: Any]] ?? []).map { item in
                let mac = item["mac"] as? String ?? ""
                return BleReconnectTarget(
                    belongConfig: item["belongConfig"] as? String ?? "",
                    uuid: item["uuid"] as? String ?? "",
                    name: item["name"] as? String ?? "",
                    expectedMacSuffix: String(mac.filter(\.isHexDigit).suffix(6)).uppercased()
                )
            }
            let source = BleConnectSource(rawValue: data["source"] as? String ?? "") ?? .unknown
            let sessionGeneration = (data["sessionGeneration"] as? NSNumber)?.int64Value ?? 0
            let acknowledgements = BleManager.shared.activateAutoReconnectTargets(
                targets,
                source: source,
                sessionGeneration: sessionGeneration
            )
            result(acknowledgements.map(\.raw))
            return
        case .notifyAutoReconnectTargetVisible:
            let data = arguments as? [String: Any] ?? [:]
            let uuid = data["uuid"] as? String ?? ""
            let name = data["name"] as? String ?? ""
            result(BleManager.shared.reconcileVisibleAutoReconnectTarget(
                uuid: uuid,
                name: name
            ))
            return
        case .disconnectDevice:
            let jsonData = arguments as? [String: Any] ?? [:]
            let uuid: String = jsonData["uuid"] as? String ?? ""
            let name: String = jsonData["name"] as? String ?? ""
            BleManager.shared.disconnect(uuid: uuid, name: name)
            break
        case .cancelAutoReconnectTargets:
            let data = arguments as? [String: Any] ?? [:]
            let targets = (data["devices"] as? [[String: Any]] ?? []).map { item in
                BleReconnectTarget(
                    belongConfig: item["belongConfig"] as? String ?? "",
                    uuid: item["uuid"] as? String ?? "",
                    name: item["name"] as? String ?? ""
                )
            }
            let reason = data["reason"] as? String ?? ""
            // iOS cannot remove a system bond programmatically; removeBond is intentionally
            // accepted by the shared Dart contract but only Android consumes it.
            BleManager.shared.cancelAutoReconnectTargets(targets, reason: reason)
            result(nil)
            return
        case .reconcileBusinessConnections:
            // iOS 的 CoreBluetooth pending reconnect 由现有 coordinator 管理。
            // 保留显式 no-op 让跨平台 API 对称，不能在此重建 peripheral 或发送假终态。
            result(nil)
            return
        case .disconnectForOtaReboot:
            let jsonData = arguments as? [String: Any] ?? [:]
            let uuid: String = jsonData["uuid"] as? String ?? ""
            let name: String = jsonData["name"] as? String ?? ""
            BleManager.shared.disconnectForOtaReboot(uuid: uuid, name: name)
            break
        case .sendCmd:
            let jsonData: [String: Any] = arguments as? [String: Any] ?? [:]
            let uuid: String = jsonData["uuid"] as? String ?? ""
            let psType: Int = jsonData["psType"] as? Int ?? 0
            // 默认 false；只有上层协议白名单可以显式放行 OTA 恢复控制指令。
            let allowDuringUpgrade: Bool = jsonData["allowDuringUpgrade"] as? Bool ?? false
            if let data = jsonData["data"] as? FlutterStandardTypedData {
                BleManager.shared.sendCmd(
                    uuid: uuid,
                    data: data.data,
                    psType: psType,
                    allowDuringUpgrade: allowDuringUpgrade
                )
            }
            // CoreBluetooth does not expose a reliable per-packet success callback here;
            // return after enqueueing to preserve the historical Dart contract.
            result(nil)
            return
        case .sendCmdNoWait:
            let jsonData: [String: Any] = arguments as? [String: Any] ?? [:]
            let uuid: String = jsonData["uuid"] as? String ?? ""
            let psType: Int = jsonData["psType"] as? Int ?? 0
            guard let data = jsonData["data"] as? FlutterStandardTypedData else {
                result(nil)
                return
            }
            BleManager.shared.sendCmdNoWait(uuid: uuid, data: data.data, psType: psType, result: result)
            return
        case .enterUpgradeState:
            let uuid = arguments as? String ?? ""
            BleManager.shared.enterUpgradeState(uuid: uuid)
            break
        case .quiteUpgradeState:
            let uuid = arguments as? String ?? ""
            BleManager.shared.quiteUpgradeState(uuid: uuid)
            break
        case .setConnectionTraceEnabled:
            BleManager.shared.setConnectionTraceEnabled(arguments as? Bool == true)
            break
        case .cleanConnectCache:
            BleManager.shared.cleanConnectCache()
            break
        case .drainAutoReconnectEvents:
            result(BleManager.shared.drainAutoReconnectEvents())
            return
        case .resetBle:
            // 1、reset 只清理当前 runtime；持久 reconnect owner 保留给下次普通恢复流程。
            BleManager.shared.reset()
            break
        case .openBleSettings:
            if let url = URL(string: "App-Prefs:root=Bluetooth"), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            break
        case .openAppSettings:
            if let settingsURL = URL(string: UIApplication.openSettingsURLString),
               UIApplication.shared.canOpenURL(settingsURL) {
                UIApplication.shared.open(settingsURL, options: [:], completionHandler: nil)
            }
            break
        default:
            break
        }
        result(nil)
    }
}
