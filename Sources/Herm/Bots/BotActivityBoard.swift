import SwiftUI

/// What a Bot is doing right now, ranked so the strongest signal wins:
/// waiting on you beats working, working beats an unseen result.
enum BotActivityStatus: Int, Comparable, Sendable {
    case idle, finished, working, blocked

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A session's state in the gateway's live list (`session.active_list`).
enum BotLiveSessionStatus: Equatable, Sendable {
    case working, waiting, idle

    init(wire: String?) {
        switch wire {
        case "waiting": self = .waiting
        case "idle", nil: self = .idle
        default: self = .working
        }
    }
}

/// The only session fields the board reads. Previews, titles and timestamps
/// change on every streamed event; leaving them out means streaming never
/// re-resolves the board.
struct BotSessionSignal: Equatable, Sendable {
    let id: String
    let profileID: String?
    let isWorking: Bool
    let hasUnreadUpdate: Bool

    init(id: String, profileID: String?, isWorking: Bool = false, hasUnreadUpdate: Bool = false) {
        self.id = id
        self.profileID = profileID
        self.isWorking = isWorking
        self.hasUnreadUpdate = hasUnreadUpdate
    }

    init(_ session: HermesSession) {
        self.init(
            id: session.id, profileID: session.profileID, isWorking: session.isWorking,
            hasUnreadUpdate: session.hasUnreadUpdate)
    }
}

/// Event-driven signals Herm already tracks per session. They change the
/// moment a turn starts, finishes or asks for approval, so the board does not
/// wait for the next roster poll.
struct BotActivitySignals: Equatable, Sendable {
    /// One signal per session, freshest first: the open Bot's rows win over
    /// the all-Bot scan's.
    var sessions: [BotSessionSignal] = []
    /// Durable session ID → owning profile, for sessions waiting on the user.
    var attention: [String: String?] = [:]
    /// The profile that owns rows Hermes returned without a profile ID.
    var scopeProfileID: String?
}

/// The one answer to "which Bots are working, blocked or done". The Bot
/// picker, the notch and every other Bot surface read this instead of
/// re-deriving it from roster flags.
struct BotActivityBoard: Equatable, Sendable {
    private(set) var statuses: [String: BotActivityStatus] = [:]
    /// Visible Bots in roster order, so every surface lists them the same way.
    private(set) var order: [String] = []

    func status(of id: String) -> BotActivityStatus { statuses[id] ?? .idle }
    func ids(_ status: BotActivityStatus) -> [String] { order.filter { statuses[$0] == status } }
    var working: [String] { ids(.working) }
    var blocked: [String] { ids(.blocked) }
    var finished: [String] { ids(.finished) }

    /// Resolves every visible Bot from the polled roster, the gateway's live
    /// session list, and the session events Herm has seen since.
    static func resolve(
        roster: [BotSummary], live: [String: BotLiveSessionStatus], signals: BotActivitySignals
    ) -> BotActivityBoard {
        var projection = Projection()
        projection.setRoster(roster, live: live)
        projection.replace(signals)
        return projection.board
    }

    /// Roster and wholesale inventory changes rebuild this index. A live
    /// session update replaces only that session's contribution to its owners.
    struct Projection {
        private var sessions: [String: BotSessionSignal] = [:]
        private var attention: [String: String?] = [:]
        private var scope: String?
        private var live: [String: BotLiveSessionStatus] = [:]
        private var rosterOwners: [String: String] = [:]
        private var visibleBots = Set<String>()
        private var workingBots = Set<String>()
        private var contributions: [String: [String: BotActivityStatus]] = [:]
        private var botSessions: [String: [String: BotActivityStatus]] = [:]
        private(set) var board = BotActivityBoard()

        mutating func setRoster(_ roster: [BotSummary], live: [String: BotLiveSessionStatus]) {
            self.live = live
            let visible = roster.filter { !$0.isHidden }
            board.order = visible.map(\.id)
            visibleBots = Set(board.order)
            workingBots = Set(visible.filter { $0.isSessionWorking || $0.isMainChatWorking }.map(\.id))
            rosterOwners = [:]
            for bot in visible {
                for id in [bot.chat?.sessionID, bot.recentSession?.sessionID, bot.worker?.sessionID].compactMap({ $0 })
                {
                    rosterOwners[id] = bot.id
                }
            }
            rebuild()
        }

        mutating func replace(_ signals: BotActivitySignals) {
            let next = Dictionary(signals.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard next != sessions || signals.attention != attention || signals.scopeProfileID != scope else { return }
            sessions = next
            attention = signals.attention
            scope = signals.scopeProfileID
            rebuild()
        }

        mutating func update(_ signal: BotSessionSignal) {
            guard sessions[signal.id] != signal else { return }
            sessions[signal.id] = signal
            let previous = contributions.removeValue(forKey: signal.id) ?? [:]
            for bot in previous.keys {
                botSessions[bot]?[signal.id] = nil
                if botSessions[bot]?.isEmpty == true { botSessions[bot] = nil }
            }
            let next = addContribution(for: signal.id)
            for bot in Set(previous.keys).union(next.keys) { resolve(bot) }
        }

        private mutating func rebuild() {
            contributions = [:]
            botSessions = [:]
            board.statuses = [:]
            for session in Set(sessions.keys).union(live.keys).union(attention.keys) { addContribution(for: session) }
            for bot in board.order { resolve(bot) }
        }

        @discardableResult
        private mutating func addContribution(for id: String) -> [String: BotActivityStatus] {
            let signal = sessions[id]
            let owner = rosterOwners[id] ?? signal.flatMap { $0.profileID ?? scope }
            var statuses: [String: BotActivityStatus] = [:]
            if let owner, visibleBots.contains(owner) {
                if live[id] == .waiting {
                    statuses[owner] = .blocked
                } else if live[id] == .working || signal?.isWorking == true {
                    statuses[owner] = .working
                } else if signal?.hasUnreadUpdate == true {
                    statuses[owner] = .finished
                }
            }
            if let target = attention[id], let bot = target ?? owner ?? scope, visibleBots.contains(bot) {
                statuses[bot] = .blocked
            }
            if !statuses.isEmpty {
                contributions[id] = statuses
                for (bot, status) in statuses { botSessions[bot, default: [:]][id] = status }
            }
            return statuses
        }

        private mutating func resolve(_ bot: String) {
            let rosterStatus: BotActivityStatus = workingBots.contains(bot) ? .working : .idle
            let status = max(rosterStatus, botSessions[bot]?.values.max() ?? .idle)
            board.statuses[bot] = status == .idle ? nil : status
        }
    }
}

extension EnvironmentValues {
    /// The shared board, injected once at each root (the Herm window/panel and
    /// the notch) so every Bot face and row reads the same status. nil outside
    /// those roots, where views fall back to the roster's own flags.
    @Entry var botActivity: BotActivityBoard?
}

extension BotActivityBoard {
    /// Working or waiting on you: the Bot is in a turn right now.
    func isBusy(_ id: String) -> Bool { status(of: id) >= .working }

    /// The face a Bot wears for its status when no caller overrides it.
    func mood(for id: String) -> BotMood {
        switch status(of: id) {
        case .working: .tool
        case .blocked: .approval
        case .finished, .idle: .idle
        }
    }
}
