import Combine
import Foundation

enum SessionActivityInspectorPresentation {
    enum Pane: String, CaseIterable { case overview = "Overview", history = "History" }
    enum Status: String, CaseIterable {
        case all = "All statuses", active = "In progress", attention = "Needs attention", finished =
            "Finished"
    }
    static let sources: [SessionActivityOverviewPresentation.Source] = [
        .session, .agent, .bot, .kanban, .background,
    ]

    struct Filter: Equatable, Hashable {
        var query = ""
        var source: SessionActivityOverviewPresentation.Source?
        var status = Status.all

        func matches(_ row: SessionActivityOverviewPresentation.TimelineRow) -> Bool {
            if let source, row.source != source { return false }
            let value = row.status.lowercased()
            let attention = ["fail", "error", "block", "wait", "triage", "interrupt"].contains {
                value.contains($0)
            }
            let active = AgentActivityPresentation.isActiveStatus(row.status)
            let finished = ["complete", "done", "cancel", "finish", "success"].contains {
                value.contains($0)
            }
            switch status {
            case .all: break
            case .active: if !active { return false }
            case .attention: if !attention { return false }
            case .finished: if !finished { return false }
            }
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty
                || [row.title, row.actor, row.detail, row.status, row.relatedSessionID]
                    .compactMap { $0 }.contains { $0.localizedStandardContains(query) }
        }
    }

    struct TranscriptEntry: Equatable {
        let id: UUID
        let calls: [ActiveToolCall]
        let botReply: BotActivityRecord?
        var error: SessionActivityOverviewPresentation.TimelineRow? = nil
    }

    /// Ordinary reply text is deliberately absent: token streaming must not
    /// invalidate the execution projection or re-sort its history.
    static func transcript(_ messages: [ChatMessage], originSessionID: String?) -> [TranscriptEntry] {
        messages.enumerated().compactMap { index, message in
            var reply: BotActivityRecord?
            if let originSessionID, let botID = message.botProfileID, message.role == .hermes,
                message.hasBodyText
            {
                let request =
                    index > 0 && messages[index - 1].role == .user ? messages[index - 1].text : "Bot response"
                reply = BotActivityRecord(
                    id: "message:\(message.id)", originSessionID: originSessionID,
                    botID: botID, botName: message.botDisplayName ?? botID,
                    summary: request, state: .completed, createdAt: message.timestamp,
                    updatedAt: message.timestamp, result: message.text
                )
            }
            let error: SessionActivityOverviewPresentation.TimelineRow? = message.isError ? .init(
                id: "error:\(message.id)", source: .session, title: "Session error", status: "Failed",
                actor: nil, timestamp: message.timestamp, detail: message.text, diffPreview: nil,
                durationSeconds: nil, startedAt: nil, completedAt: message.timestamp
            ) : nil
            guard !message.activity.isEmpty || reply != nil || error != nil else { return nil }
            return TranscriptEntry(id: message.id, calls: message.activity, botReply: reply, error: error)
        }
    }

    static func scopedBots(
        records: [BotActivityRecord], transcript: [TranscriptEntry], sessionIDs: Set<String>
    ) -> [BotActivityRecord] {
        var scoped = records.filter { sessionIDs.contains($0.originSessionID) }
        let knownResults = Set(scoped.compactMap { record in record.result.map { "\(record.botID)\u{0}\($0)" } })
        scoped.append(
            contentsOf: transcript.compactMap(\.botReply).filter {
                sessionIDs.contains($0.originSessionID) && !knownResults.contains("\($0.botID)\u{0}\($0.result ?? "")")
            })
        return scoped.sorted { $0.id < $1.id }
    }

    /// A live update wins over a restored copy of the same call.
    static func calls(transcript: [TranscriptEntry], live: [ActiveToolCall]) -> [ActiveToolCall] {
        var calls: [String: ActiveToolCall] = [:]
        for entry in transcript { for call in entry.calls { calls[call.id] = call } }
        for call in live { calls[call.id] = call }
        return calls.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
    }
}

@MainActor
final class SessionActivityInspectorModel: ObservableObject {
    typealias Presentation = SessionActivityOverviewPresentation
    @Published private(set) var snapshot = Presentation.Snapshot(
        agents: [], work: [], timeline: [], liveAgentCount: 0, blockedWorkCount: 0
    )
    private(set) var results: [Presentation.TimelineRow] = []
    private var history: [Presentation.TimelineRow] = []
    @Published private(set) var filteredHistory: [Presentation.TimelineRow] = []
    private var selection = SessionActivityInspectorPresentation.Filter()
    private var previous: Inputs?
    private(set) var projectionCount = 0

    private struct Inputs: Equatable {
        let sessionID: String?
        let aliases: Set<String>
        let transcript: [SessionActivityInspectorPresentation.TranscriptEntry]
        let live: AgentPresentationSnapshot
        let calls: [ActiveToolCall]
        let bots: [BotActivityRecord]
        let tasks: [KanbanTaskSummary]
        let background: [HermesBackgroundTask]
        let isWorking: Bool
    }

    func update(model: DockModel, control: ControlCenterModel, sessionID: String?) {
        let aliases = Set(model.botActivitySessionIDs.compactMap { $0 }.filter { !$0.isEmpty })
        let transcript = SessionActivityInspectorPresentation.transcript(
            model.messages, originSessionID: model.navigationSessionID)
        let inputs = Inputs(
            sessionID: sessionID, aliases: aliases, transcript: transcript,
            live: model.agentPresentationSnapshot, calls: model.activeToolCalls,
            bots: aliases.sorted().flatMap { model.botActivityBySessionID[$0] ?? [] },
            tasks: sessionID != nil && control.sessionKanbanSessionID == sessionID
                ? control.sessionKanbanTasks : [],
            background: model.backgroundTasks.filter { aliases.contains($0.parentSessionID) },
            isWorking: model.status == .working
        )
        guard inputs != previous else { return }
        previous = inputs
        projectionCount += 1
        let bots = SessionActivityInspectorPresentation.scopedBots(
            records: inputs.bots, transcript: transcript, sessionIDs: aliases
        )
        let agents = AgentPresentationSnapshot(
            displayedSubagents: inputs.live.displayedSubagents,
            pipeline: AgentActivityPresentation.pipeline(
                activities: model.agentActivities,
                toolCalls: SessionActivityInspectorPresentation.calls(
                    transcript: transcript, live: inputs.calls),
                subagents: inputs.live.displayedSubagents
            ),
            activityCountsByAgentID: inputs.live.activityCountsByAgentID,
            activeAgentIDs: inputs.live.activeAgentIDs, revision: inputs.live.revision
        )
        snapshot = Presentation.makeSnapshot(
            agentSnapshot: agents, botRecords: bots, kanbanTasks: inputs.tasks,
            isTurnActive: inputs.isWorking, backgroundTasks: inputs.background, sessionEvents: transcript.compactMap(\.error)
        )
        let workIDs = Set(snapshot.work.map(\.id))
        results = snapshot.timeline.filter {
            $0.source != .session && $0.source != .agent && !workIDs.contains($0.id)
                && !AgentActivityPresentation.isActiveStatus($0.status)
        }
        history =
            snapshot.timeline
            + snapshot.work.compactMap { row in
                guard let task = row.kanbanTask else { return nil }
                return Presentation.TimelineRow(
                    id: row.id, source: .kanban, title: row.title, status: row.status,
                    actor: row.actor, timestamp: row.updatedAt, detail: row.detail ?? row.result,
                    diffPreview: nil, durationSeconds: nil, startedAt: task.startedAt,
                    completedAt: task.completedAt, kanbanTask: task
                )
            }
        history.sort {
            if $0.timestamp != $1.timestamp {
                return ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
            }
            return $0.id < $1.id
        }
        filter(selection)
    }

    func filter(_ selection: SessionActivityInspectorPresentation.Filter) {
        self.selection = selection
        filteredHistory = history.filter(selection.matches)
    }
}
