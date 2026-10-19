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
