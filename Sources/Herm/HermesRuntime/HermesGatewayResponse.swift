import Foundation

/// Only immutable JSONSerialization graphs enter this envelope. Construction is
/// private so caller-owned mutable Foundation collections cannot cross actors.
struct HermesGatewayResponse: @unchecked Sendable {
    let object: [String: Any]

    private init(object: [String: Any]) {
        self.object = object
    }

    nonisolated static func decode(
        _ message: URLSessionWebSocketTask.Message,
        jsonSerialization: JSONSerialization.Type = JSONSerialization.self
    ) -> Self? {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? jsonSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self(object: object)
    }

    var result: Self {
        Self(object: object["result"] as? [String: Any] ?? [:])
    }
}
