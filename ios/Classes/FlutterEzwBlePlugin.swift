import Flutter
import UIKit

/// 全局参数
/// - 函数频道名称
let EZW_BLE_CHANNEL_NAME: String = "flutter_ezw_ble"

public class FlutterEzwBlePlugin: NSObject, FlutterPlugin, FlutterApplicationLifeCycleDelegate {
    /// 当前进程是否由 CoreBluetooth restoration identifier 唤醒。
    ///
    /// `willRestoreState` 不是 Bluetooth 后台拉起的必要条件：系统可以只通过 launch
    /// option 恢复 central 会话，再由宿主重新提交长期连接目标。因此启动原因必须在
    /// App delegate 回调中独立锁存，不能依赖 peripheral escrow 是否仍然存在。
    private static var launchedForBluetoothStateRestoration = false

    /// 在 Flutter 注册 application delegate 前锁存一次性的 CoreBluetooth 启动参数。
    /// Flutter 3.41 的隐式 Engine 会在宿主 didFinishLaunching 之后才注册插件。
    public static func captureBluetoothStateRestorationLaunchOptions(
        _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        // UIScene 生命周期下 didFinishLaunching 的 launchOptions 恒为 nil，不能再把
        // bluetoothCentrals 当作重建 restoration manager 的前置条件。每次原生进程
        // 启动都用同一 restore identifier 立即重建 manager；若系统有保存状态，
        // willRestoreState 会把 peripheral 交给现有 escrow，等待 Flutter 业务认领。
        // 这里只做原生同步构造，不启动 Dart 业务，也不会给前台启动增加 await。
        let _ = BleManager.shared

        let centralIdentifiers = launchOptions?[.bluetoothCentrals] as? [String] ?? []
        guard centralIdentifiers.contains(BleManager.restorationIdentifier) else {
            return
        }

        launchedForBluetoothStateRestoration = true
        BleEC.logger.emit(
            "[d]-stateRestoration: app launched for bluetooth central id=\(BleManager.restorationIdentifier)"
        )
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterEzwBlePlugin()
        //  MethodChannel
        let methodChannel = FlutterMethodChannel(name: EZW_BLE_CHANNEL_NAME, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        // CoreBluetooth 后台拉起信息只存在于 didFinishLaunching launchOptions；插件
        // 必须注册 application delegate 才能在 Flutter 业务初始化前锁存该事实。
        registrar.addApplicationDelegate(instance)
        //  EvenChannel
        BleEC.allCases.forEach { child in
           child.registerEventChannel(registrar: registrar, streamHandler: instance)
        }
        //  初始化蓝牙
        let _ = BleManager.shared
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.captureBluetoothStateRestorationLaunchOptions(launchOptions)
        return true
    }

    /// 只读返回当前进程的 CoreBluetooth 启动原因，不 claim peripheral、不启动 GATT。
    static func wasLaunchedForBluetoothStateRestoration() -> Bool {
        launchedForBluetoothStateRestoration
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
