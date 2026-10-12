import Foundation

// External utility conveniences used by the unchanged production pipeline.
public extension String {
    var isNotEmpty: Bool { !isEmpty }
}

public extension Array {
    var isNotEmpty: Bool { !isEmpty }
}

public extension Encodable {
    func toJsonString() throws -> String? {
        String(data: try JSONEncoder().encode(self), encoding: .utf8)
    }
}
