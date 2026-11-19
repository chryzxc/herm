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
        let visible = roster.filter { !$0.isHidden }
        let visibleIDs = Set(visible.map(\.id))
        // Session → owning Bot. Roster pointers are exact; session rows fill in
        // every other session, so a Bot running more than its latest chat counts.
        var owner: [String: String] = [:]
        for session in signals.sessions {
            if let profile = session.profileID ?? signals.scopeProfileID { owner[session.id] = profile }
        }
        for bot in visible {
            for id in [bot.chat?.sessionID, bot.recentSession?.sessionID, bot.worker?.sessionID].compactMap({ $0 }) {
                owner[id] = bot.id
            }
        }
        var statuses: [String: BotActivityStatus] = [:]
        func raise(_ id: String?, _ status: BotActivityStatus) {
            guard let id, visibleIDs.contains(id), status > (statuses[id] ?? .idle) else { return }
            statuses[id] = status
        }
        for bot in visible where bot.isSessionWorking || bot.isMainChatWorking {
            raise(bot.id, .working)
        }
        for (sessionID, status) in live {
            switch status {
            case .waiting: raise(owner[sessionID], .blocked)
            case .working: raise(owner[sessionID], .working)
            case .idle: break
            }
        }
        for session in signals.sessions {
            if session.isWorking {
                raise(owner[session.id], .working)
            } else if session.hasUnreadUpdate {
                raise(owner[session.id], .finished)
            }
        }
        for (sessionID, profile) in signals.attention {
            raise(profile ?? owner[sessionID] ?? signals.scopeProfileID, .blocked)
        }
        return BotActivityBoard(statuses: statuses, order: visible.map(\.id))
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
