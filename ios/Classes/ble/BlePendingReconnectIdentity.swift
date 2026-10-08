import Foundation

/// 空 UUID 的 iOS 目标由名称身份 owner 暂存，等待扫描补齐 CoreBluetooth UUID。
struct BlePendingReconnectIdentity {
    let belongConfig: String
    let name: String
    let expectedMacSuffix: String
    var source: BleConnectSource
    /// Dart session generation for name-only owners; legacy callers fall back to 0.
    let sessionGeneration: Int64
    /// A pending identity must preserve the same transport barrier as a UUID task.
    var recoveryGate: BlePendingIdentityRecoveryGate

    init(
        belongConfig: String,
        name: String,
        expectedMacSuffix: String,
        source: BleConnectSource,
        sessionGeneration: Int64 = 0,
        recoveryGate: BlePendingIdentityRecoveryGate = BlePendingIdentityRecoveryGate(
            recoveryEpoch: 0,
            awaitingRecoveryActivation: false
        )
    ) {
        self.belongConfig = belongConfig
        self.name = name
        self.expectedMacSuffix = expectedMacSuffix
        self.source = source
        self.sessionGeneration = sessionGeneration
        self.recoveryGate = recoveryGate
    }

    /// 配置名与完整广播名共同组成唯一 owner，避免仅凭 R1 前缀误连附近设备。
    var key: String {
        "\(belongConfig.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|" +
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// MAC 提示只做附加约束；历史缓存缺失 MAC 时仍以完整名称作为身份事实。
    func matches(belongConfig candidateConfig: String, advertisedName: String) -> Bool {
        guard candidateConfig.caseInsensitiveCompare(belongConfig) == .orderedSame,
              advertisedName == name else {
            return false
        }
        let suffix = expectedMacSuffix.filter(\.isHexDigit).uppercased()
        return suffix.isEmpty || advertisedName.filter(\.isHexDigit).uppercased().hasSuffix(suffix)
    }
}

