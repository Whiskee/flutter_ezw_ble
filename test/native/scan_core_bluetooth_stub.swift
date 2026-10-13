import Foundation

// Only the platform boundary is replaced. The test compiles the complete
// production scan pipeline, pending resolver, identity model and recovery gate.
public let CBAdvertisementDataLocalNameKey = "kCBAdvDataLocalName"
public let CBAdvertisementDataServiceUUIDsKey = "kCBAdvDataServiceUUIDs"

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

public final class CBUUID {
    public let uuidString: String
    public init(string: String) {
        self.uuidString = string
    }
}

public final class CBCentralManager {
    public var state: CBManagerState = .poweredOn
    public init() {}
}
