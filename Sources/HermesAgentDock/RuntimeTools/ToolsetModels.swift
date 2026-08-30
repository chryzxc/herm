import Foundation

enum RuntimeToolset: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case browser
    case computerUse
    case lsp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: "Terminal backend"
        case .browser: "Browser"
        case .computerUse: "Computer use"
        case .lsp: "Language server"
        }
    }
    var payloadKey: String {
        switch self { case .computerUse: "computer_use"; default: rawValue }
    }
}

enum RuntimeBackendState: String, Equatable, Sendable {
    case available
    case requiresSetup
    case unavailable
    case unsupported
}

struct RuntimeBackendStatus: Identifiable, Equatable, Sendable {
    let id: RuntimeToolset
    let state: RuntimeBackendState
    let detail: String

    var isAvailable: Bool { state == .available }
}

struct ToolsetEntry: Identifiable, Equatable, Sendable {
    let id: String
    let isEnabled: Bool
    let detail: String
}

enum ToolsetChange: Equatable, Sendable {
    case enable
    case disable
}

enum ToolsetChangeResult: Equatable, Sendable {
    case unavailable(String)
    case confirmationRequired
    case appliesNextSession
}

struct ToolsetSnapshot: Equatable, Sendable {
    let toolsets: [ToolsetEntry]
    let backends: [RuntimeBackendStatus]
    let activeSessionID: String?
    let restartRequired: Bool

    func backend(_ toolset: RuntimeToolset) -> RuntimeBackendStatus? {
        backends.first { $0.id == toolset }
    }
}
