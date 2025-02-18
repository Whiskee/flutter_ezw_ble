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
        BleMC(rawValue: call.method)?.handle(arguments: call.arguments, result: result)
    }
    
}
