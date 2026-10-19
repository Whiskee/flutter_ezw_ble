/// Process-local iOS Debug policy, independent of BLE manager construction.
///
/// MethodChannel, CoreBluetooth (queue: nil) and the OTA scheduler share the main
/// queue. Updating this value must not initialize a central, touch owners or clear
/// Trace. Default-off also covers native startup before Dart applies its setting.
enum BleDebugLogPolicy {
    private(set) static var isEnabled = false

    static func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Keep interpolation and EventChannel buffering behind the same early gate.
    static func emit(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        BleEC.logger.emit(message())
    }
}
