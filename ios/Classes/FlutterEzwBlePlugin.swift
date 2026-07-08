import Flutter
import UIKit

/// 全局参数
/// - 函数频道名称
let EZW_BLE_CHANNEL_NAME: String = "flutter_ezw_ble"

public class FlutterEzwBlePlugin: NSObject, FlutterPlugin {
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterEzwBlePlugin()
        //  MethodChannel
        let methodChannel = FlutterMethodChannel(name: EZW_BLE_CHANNEL_NAME, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        //  EvenChannel
        BleEC.allCases.forEach { child in
           child.registerEventChannel(registrar: registrar, streamHandler: instance)
        }
        //  初始化蓝牙
        let _ = BleManager.shared
    }
   
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let method = BleMC(rawValue: call.method) else {
            // MethodChannel 必须对每个 Dart 调用返回结果；未知方法如果静默丢弃，
            // Dart 侧 Future 会永久 pending，最终表现为启动或操作超时。
            result(FlutterMethodNotImplemented)
            return
        }
        method.handle(arguments: call.arguments, result: result)
    }
    
}
