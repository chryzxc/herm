import Foundation

/// The bounded, user-visible surfaces exposed by the Operations view.
enum OperationsSurface: String, CaseIterable, Equatable, Sendable {
    case monitoring
    case insights
    case logs
    case dashboard
    case proxy
    case apiServer = "api-server"
    case acp
    case promptSize = "prompt-size"
    case gatewayServer = "gateway-server"

    var title: String {
        switch self {
        case .monitoring: "Monitoring"
        case .insights: "Insights"
        case .logs: "Logs"
        case .dashboard: "Dashboard"
        case .proxy: "Proxy"
        case .apiServer: "API server"
        case .acp: "ACP"
        case .promptSize: "Prompt size"
        case .gatewayServer: "Gateway server"
        }
    }
}

enum OperationsStatus: String, Equatable, Sendable {
    case ready
    case running
    case stopped
    case degraded
    case unknown
    case unavailable
}

enum OperationsFormatSupport: Equatable, Sendable {
    case structured
    case humanReadable
    case unsupported

    var notice: String? {
        switch self {
        case .structured: nil
        case .humanReadable: "Structured status is unavailable; human-readable output is display-only."
        case .unsupported: "A supported status format is unavailable."
        }
    }
}

struct OperationsStatusCard: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: OperationsStatus
    let detail: String
    let formatSupport: OperationsFormatSupport
    var isStale: Bool = false

    init(id: String, title: String, status: OperationsStatus, detail: String, formatSupport: OperationsFormatSupport, isStale: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = OperationsStatusProjection.sanitize(detail)
        self.formatSupport = formatSupport
        self.isStale = isStale
    }

    var isFormatUnsupported: Bool { formatSupport != .structured }
    var formatNotice: String? { formatSupport.notice }
}

struct OperationsStatusSnapshot: Equatable, Sendable {
    let cards: [OperationsStatusCard]

    init(cards: [OperationsStatusCard]) {
        self.cards = cards
    }

    static let unavailable = OperationsStatusSnapshot(cards: OperationsSurface.allCases.map {
        OperationsStatusCard(
            id: $0.rawValue,
            title: $0.title,
            status: .unavailable,
            detail: "Status is unavailable. Reconnect Hermes and refresh.",
            formatSupport: .unsupported
        )
    })
}

/// A generation-guarded projection. Refresh never clears a successful value;
/// failures retain it as stale and expose only a safe, bounded message.
struct OperationsStatusProjection: Equatable, Sendable {
    private(set) var state: HermesProjectionState<OperationsStatusSnapshot>
    private(set) var isRefreshing = false
    private(set) var generation = 0

    init(snapshot: OperationsStatusSnapshot? = nil) {
        state = snapshot.map(HermesProjectionState.ready) ?? .loading
    }

    @discardableResult
    mutating func beginRefresh() -> Int {
        generation += 1
        isRefreshing = true
        return generation
    }

    @discardableResult
    mutating func succeed(with snapshot: OperationsStatusSnapshot, generation: Int? = nil) -> Bool {
        guard generation == nil || generation == self.generation else { return false }
        self.state = .ready(snapshot)
        isRefreshing = false
        return true
    }

    mutating func failRefresh(message: String) {
        isRefreshing = false
        switch state {
        case .ready(let snapshot), .stale(let snapshot, _):
            state = .stale(snapshot, safeMessage: Self.sanitize(message))
        default:
            state = .unavailable(safeMessage: Self.sanitize(message))
        }
    }

    var displayCards: [OperationsStatusCard] {
        switch state {
        case .ready(let snapshot): snapshot.cards
        case .stale(let snapshot, _): snapshot.cards.map { card in
            var copy = card
            copy.isStale = true
            return copy
        }
        default: []
        }
    }

    var safeMessage: String? {
        switch state {
        case .stale(_, let message), .unavailable(let message), .failed(let message): message
        default: nil
        }
    }

    static func sanitize(_ message: String) -> String {
        let redacted = message
            .replacingOccurrences(of: #"/(Users|private|var|tmp)/[^\s]+"#, with: "[path]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|password|secret|bearer|api[_-]?key)=\S+"#, with: "$1=[redacted]", options: .regularExpression)
        let compact = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((compact.isEmpty ? "Refresh failed." : compact).prefix(240))
    }
}

enum OperationsProcessKind: String, Equatable, Sendable {
    case gatewayServer = "gateway-server"
    case proxy
    case apiServer = "api-server"
    case acp
}

struct OperationsProcessIdentity: Equatable, Sendable {
    let kind: OperationsProcessKind
    let instanceID: String
}

struct OperationsControlRequest: Equatable, Sendable {
    let action: OperationsControlAction
    let identity: OperationsProcessIdentity
    let timeout: Duration
    let confirmed: Bool
}

enum OperationsControlAction: String, Equatable, Sendable { case start, stop }
enum OperationsControlDecision: Equatable, Sendable {
    case confirmationRequired
    case awaitingReadBack
    case accepted
    case identityMismatch
    case invalidTimeout
    case unavailable
}

/// Policy-only gate for lifecycle controls. It never starts/stops a process;
/// callers must perform an allow-listed operation and read back this identity.
enum OperationsControlGate {
    static func validate(
        request: OperationsControlRequest,
        observed: OperationsProcessIdentity?
    ) -> OperationsControlDecision {
        guard request.confirmed else { return .confirmationRequired }
        guard request.timeout > .zero else { return .invalidTimeout }
        guard let observed else { return .awaitingReadBack }
        guard observed == request.identity else { return .identityMismatch }
        return .accepted
    }
}
