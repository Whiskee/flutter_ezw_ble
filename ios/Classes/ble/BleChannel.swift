//
//  BleChannel.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

import Flutter

typealias EvenConnectStreamHandler = NSObject & FlutterStreamHandler

/// Event Channel 事件存储
private var bleEvents: Dictionary<String, FlutterEventSink> = [:]
private var pendingBleEvents: Dictionary<String, [Any]> = [:]

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
    //  打印iOS日志
    case logger
    
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

    func emit(_ value: Any) {
        if let event = event() {
            event(value)
            return
        }
        var pending = pendingBleEvents[eventLabel] ?? []
        pending.append(value)
        if pending.count > 120 {
            pending.removeFirst(pending.count - 120)
        }
        pendingBleEvents[eventLabel] = pending
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
        if let pending = pendingBleEvents.removeValue(forKey: eventName) {
            pending.forEach { value in
                events(value)
            }
        }
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
