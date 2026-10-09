import Foundation

// Only the platform boundary is replaced. The test compiles the complete
// production scan pipeline, pending resolver, identity model and recovery gate.
public let CBAdvertisementDataLocalNameKey = "kCBAdvDataLocalName"

public enum CBManagerState {
    case unknown, resetting, poweredOff, poweredOn
}

public final class CBPeripheral {
    public let identifier: UUID
    public var name: String?

    public init(identifier: UUID, name: String?) {
        self.identifier = identifier
        self.name = name
    }
}

public final class CBCentralManager {
    public var state: CBManagerState = .poweredOn
    public init() {}
}
