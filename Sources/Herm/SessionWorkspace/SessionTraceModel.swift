import Combine
import Foundation

@MainActor
final class SessionTraceModel: ObservableObject {
    @Published private(set) var turns: [SessionTraceTurn] = []
    @Published private(set) var connected = false
    @Published private(set) var sessionIDs = Set<String>()
    @Published private(set) var isLoading = false
    /// An expanded copy is on screen and still needs updates while the inspector is covered.
    @Published var isExpanded = false
    private var previous: Inputs?
    private var transcriptBots: [SessionBotParticipants.Participant] = []
    /// Set while hidden: a stop seen on resume happened at an unknown time.
    private var suspended = false
    private(set) var projectionCount = 0
    private(set) var historyScanCount = 0
    private(set) var updateCount = 0
    private var cachedHistory: (identity: String, revision: UInt64, turns: [SessionTraceTurn])?
    private weak var model: DockModel?
    private var subscriptions = Set<AnyCancellable>()
    private var scheduledUpdate: Task<Void, Never>?

    private struct Inputs: Equatable {
        let identity: String
        let turns: [SessionTraceTurn]
        let live: [ActiveToolCall]
        let agents: [HermesSubagent]
        let activities: [AgentActivity]
        let working: Bool
        let connected: Bool
        let botRecords: [BotActivityRecord]
        let participants: [SessionBotParticipants.Participant]
    }

    /// Hidden timelines stop projecting; the next update must not time a stop it missed.
    func suspend() {
        suspended = true
        scheduledUpdate?.cancel()
        scheduledUpdate = nil
        subscriptions.removeAll()
    }

    func observe(_ model: DockModel) {
        if self.model !== model || subscriptions.isEmpty {
            subscriptions.removeAll()
            self.model = model
            observe(model.$messages)
            observe(model.$activityPresentationRevision)
            observe(model.$botActivityRevision)
            observe(model.$status.removeDuplicates())
            observe(model.$isHermesConnected.removeDuplicates())
            observe(model.$isRestoringSession.removeDuplicates())
            observe(model.$sessions.map { Set($0.map(\.id)) }.removeDuplicates())
            observe(model.$sessionID.removeDuplicates())
            observe(model.$profileScopeID.removeDuplicates())
            observe(model.transcriptPresentationChanges.prepend(()))
        }
        update(model)
    }

    private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher.dropFirst().sink { [weak self] _ in
            guard let self, self.scheduledUpdate == nil else { return }
            self.scheduledUpdate = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let model = self.model else { return }
                self.scheduledUpdate = nil
                self.update(model)
            }
        }.store(in: &subscriptions)
    }

    func update(_ model: DockModel) {
        updateCount += 1
        defer { suspended = false }
        let identity = WorkspaceIdentity.session(model)
        // Assign only on change: every publish re-renders the whole timeline.
        let ids = Set(model.sessions.map(\.id))
        if ids != sessionIDs { sessionIDs = ids }
        if isLoading != model.isRestoringSession { isLoading = model.isRestoringSession }
        if connected != model.isHermesConnected { connected = model.isHermesConnected }
        guard model.navigationSessionID != nil, !model.isRestoringSession else {
            if !turns.isEmpty { turns = [] }
            previous = nil
            cachedHistory = nil
            transcriptBots = []
            return
        }
        var requests: [SessionTraceTurn]
        if let cachedHistory, cachedHistory.identity == identity, cachedHistory.revision == model.messagesRevision {
            requests = cachedHistory.turns
        } else {
            historyScanCount += 1
            requests = Self.requests(model.messages)
            transcriptBots = SessionBotParticipants.collect(
                messages: model.messages, activeProfileID: model.activeBotProfileID)
            cachedHistory = (identity, model.messagesRevision, requests)
        }
        if requests.isEmpty, model.streamingMessageSessionID == model.sessionID,
            let start = model.streamingResponseStartedAt
        {
            requests.append(
                SessionTraceTurn(id: "live:" + identity, title: "Current execution", start: start))
        }
        // Keep only boundaries observed while this session's trace is mounted.
        // Restored assistant timestamps have different semantics from live rows.
        if let previous, previous.identity == identity {
            let prior = Dictionary(
                previous.turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for index in requests.indices {
                requests[index].executionStart = prior[requests[index].id]?.executionStart
                requests[index].executionEnd = prior[requests[index].id]?.executionEnd
                if index == requests.count - 1, !suspended, requests[index].executionStart != nil,
                    (previous.working && model.status != .working)
                        || (previous.connected && !model.isHermesConnected)
                {
                    requests[index].executionEnd = Date()
                }
            }
        }
        if !requests.isEmpty, model.streamingMessageSessionID == model.sessionID,
            let start = model.streamingResponseStartedAt
        {
            requests[requests.count - 1].executionStart = start
        }
        let inputs = Inputs(
            identity: identity, turns: requests,
            live: model.streamingTurnActivity + model.activeToolCalls,
            agents: model.agentPresentationSnapshot.displayedSubagents,
            activities: model.agentActivities,
            working: model.status == .working, connected: model.isHermesConnected,
            botRecords: SessionBotActivityPresentation.snapshot(
                records: model.botActivityBySessionID.values.flatMap { $0 },
                sessionIDs: model.botActivitySessionIDs
            ).list, participants: transcriptBots)
        guard previous != inputs else { return }
        previous = inputs
        projectionCount += 1
        if connected != inputs.connected { connected = inputs.connected }
        var projected = SessionTraceProjection.make(
            turns: requests, live: inputs.live, agents: inputs.agents,
            working: inputs.working, connected: inputs.connected, activities: inputs.activities)
        let botTurns = SessionCrewProjection.botTurns(inputs.botRecords, connected: inputs.connected)
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        // Transcript order is authoritative, including prepended history whose
        // timestamps may arrive out of order. Insert dispatches without sorting it.
        for turn in botTurns {
            let index = projected.firstIndex { $0.start > turn.start } ?? projected.endIndex
            projected.insert(turn, at: index)
        }
        for bot in inputs.participants {
            for requestID in bot.requestIDs {
                guard let index = projected.firstIndex(where: { $0.id == requestID }) else { continue }
                projected[index].rows.append(
                    SessionTraceRow(
                        id: "transcript-bot:" + requestID + ":" + bot.id, kind: .agent, title: bot.name,
                        timing: .unavailable, outcome: "Appeared in conversation", crewProfileID: bot.id))
            }
            if bot.requestIDs.isEmpty {
                projected.append(
                    SessionTraceTurn(
                        id: "transcript-bot:" + bot.id, title: bot.name,
                        start: model.messages.first?.timestamp ?? Date(),
                        rows: [
                            SessionTraceRow(
                                id: "transcript-bot:" + bot.id, kind: .agent, title: bot.name,
                                timing: .unavailable, outcome: "Appeared in conversation", crewProfileID: bot.id)
                        ]))
            }
        }
        turns = projected
    }

    private static func requests(_ messages: [ChatMessage]) -> [SessionTraceTurn] {
        var requests: [SessionTraceTurn] = []
        for message in messages {
            if message.role == .user && !message.isSteering && message.systemEvent == nil
                && message.kanbanNotice == nil
            {
                requests.append(
                    SessionTraceTurn(
                        id: message.id.uuidString,
                        title: String(message.text.prefix(100)), start: message.timestamp))
            }
            if message.isError, !requests.isEmpty {
                requests[requests.count - 1].outcome = "Failed"
            }
            if !message.activity.isEmpty {
                if requests.isEmpty {
                    requests.append(
                        SessionTraceTurn(
                            id: "loaded:" + message.id.uuidString,
                            title: "Loaded execution",
                            start: message.activity.map(\.startedAt).min() ?? message.timestamp))
                }
                requests[requests.count - 1].calls.append(contentsOf: message.activity)
            }
        }
        return requests
    }
}
