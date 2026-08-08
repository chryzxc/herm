import Foundation

/// The small transport surface used by control-center services. Keeping this
/// separate from the concrete gateway makes capability and projection logic
/// testable without launching a Hermes process.
@MainActor
protocol HermesRPCClientProtocol: AnyObject {
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
    func connect() async throws
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
    func close()
}

extension HermesGateway: HermesRPCClientProtocol {}

@MainActor
final class HermesEventRouter {
    typealias Handler = @MainActor (String, [String: Any]) -> Void

    private var handlers: [UUID: Handler] = [:]

    @discardableResult
    func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        handlers.removeValue(forKey: id)
    }

    func route(type: String, params: [String: Any]) {
        for handler in handlers.values {
            handler(type, params)
        }
    }
}
