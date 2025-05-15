//
//  BleChannel.swift
//  Pods
//
//  Created by Whiskee on 2025/1/3.
//

import Flutter

typealias EvenConnectStreamHandler = NSObject & FlutterStreamHandler

/// Event Channel 事件存储
private var bleEvents: Dictionary<String, FlutterEventSink> = [:]

/// Method Channel
enum BleMC: String {
    case getPlatformVersion
    //  当前蓝牙状态
    //  - unknown = 0
    //  - resetting = 1
    //  - unsupported = 2
    //  - unauthorized = 3
    //  - poweredOff = 4
    //  - poweredOn = 5
    case bleState
    //  设置蓝牙配置
    case initConfigs
    //  开始扫描设备
    case startScan
    //  停止扫描设备
    case stopScan
    //  连接设备(uuid)
    case connectDevice
    //  断连设备(uuid)
    case disconnectDevice
    //  主动回复设备连接成功
    case deviceConnected
    //  发送指令
    case sendCmd
    //  进入升级模式
    case enterUpgradeState
    //  退出升级模式
    case quiteUpgradeState
    //  打开蓝牙设置页面
    case openBleSettings
    //  打开App设置页面
    case openAppSettings
    //  未知
    case unknown
    
    /**
     *  处理回调结果
     */
    func handle(arguments: Any?,  result: @escaping FlutterResult) {
        switch self {
        case .getPlatformVersion:
            result("iOS " + UIDevice.current.systemVersion)
            return
        case .bleState:
            result(BleManager.shared.currentBleState)
            return
        case .initConfigs:
            let jsonArray: Array<[String:Any]> = arguments as? Array<[String:Any]> ?? []
            let configs: Array<BleConfig?> = jsonArray
                .map { jsonData in
                    jsonData.decodeTo()
                }
                .filter { $0 != nil }
            BleManager.shared.initConfigs(configs: configs.map { $0! })
            break
        case .startScan:
            let belongConfig: String = arguments as? String ?? ""
            BleManager.shared.startScan(bleongConfig: belongConfig)
            break
        case .stopScan:
            BleManager.shared.stopScan()
            break
        case .connectDevice:
            let jsonData: [String:Any] = arguments as? [String:Any] ?? [:]
            let belongConfig: String = jsonData["belongConfig"] as? String ?? ""
            let uuid = jsonData["uuid"] as? String ?? ""
            let afterUpgrade = jsonData["afterUpgrade"] as? Bool ?? false
            BleManager.shared.connect(belongConfig: belongConfig, uuid: uuid, afterUpgrade: afterUpgrade)
            break
        case .deviceConnected:
            let uuid = arguments as? String ?? ""
            BleManager.shared.setConnected(uuid: uuid)
            break
        case .disconnectDevice:
            let uuid = arguments as? String ?? ""
            BleManager.shared.disconnect(uuid: uuid)
            break
        case .sendCmd:
            let jsonData: [String:Any] = arguments as? [String:Any] ?? [:]
            let uuid: String = jsonData["uuid"] as? String ?? ""
            let psType: Int = jsonData["psType"] as? Int ?? 0
            if let data = jsonData["data"] as? FlutterStandardTypedData {
                BleManager.shared.sendCmd(uuid: uuid, data: data.data, psType: psType)
            }
            break
        case .enterUpgradeState:
            let uuid = arguments as? String ?? ""
            BleManager.shared.enterUpgradeState(uuid: uuid)
            break
        case .quiteUpgradeState:
            let uuid = arguments as? String ?? ""
            BleManager.shared.quiteUpgradeState(uuid: uuid)
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


/// Event Channel
enum BleEC: String, CaseIterable {
    
    //  蓝牙状态
    case bleState
    //  扫描结果
    case scanResult
    //  连接状态
    case connectStatus
    //  接收数据
    case receiveData
    
    private var eventLabel: String {
        get {
            return "\(EZW_BLE_CHANNEL_NAME)_\(rawValue)"
        }
    }
    
    /**
     *  注册EventChannel
     */
    func registerEventChannel(registrar: FlutterPluginRegistrar, streamHandler: EvenConnectStreamHandler) {
        let eventChannel = FlutterEventChannel(name: eventLabel, binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(streamHandler)
    }
    
    /**
     *  获取event
     */
    func event() -> FlutterEventSink? {
        guard bleEvents.contains(where: { (key, _) in
            key == eventLabel
        }) else {
            return nil
        }
        return bleEvents[eventLabel]
    }
}


/// 事件频道信息流处理对象
extension FlutterEzwBlePlugin: FlutterStreamHandler {
    /**
     *  接收监听事件
     *  - 说明：Flutter层创建EventChannel时必须在receiveBroadcastStream中添加接收对象的Tag，即：EventChannel(tag).receiveBroadcastStream(tag)，否则arguments永远为空
     */
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard let eventName = arguments as? String else {
            return nil
        }
        bleEvents[eventName] = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        guard let eventName = arguments as? String else {
            return nil
        }
        bleEvents.removeValue(forKey: eventName)
        return nil
    }
    
}
