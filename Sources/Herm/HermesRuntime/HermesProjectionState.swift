import Foundation

/// The UI-safe lifecycle of a read-only Hermes projection.
///
/// Raw transport errors do not cross this boundary. Callers provide a concise,
/// user-safe message for states that need recovery guidance.
enum HermesProjectionState<Value: Equatable & Sendable>: Equatable, Sendable {
    case loading
    case ready(Value)
    case stale(Value, safeMessage: String)
    case empty
    case unavailable(safeMessage: String)
    case failed(safeMessage: String)
}
