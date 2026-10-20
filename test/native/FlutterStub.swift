import Foundation

// StandardMessageCodec's byte container is the only extra bridge dependency
// needed to compile the actual FILE MethodChannel/manager methods on the host.
public final class FlutterStandardTypedData {
    public let data: Data
    public init(bytes: Data) { data = bytes }
}

public final class FlutterError: Error {
    public let code: String
    public let message: String?
    public let details: Any?

    public init(code: String, message: String?, details: Any?) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public typealias FlutterResult = (Any?) -> Void
