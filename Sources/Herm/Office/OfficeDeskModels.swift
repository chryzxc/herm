import Foundation

struct OfficeSessionActivity {
    private let aliases: [ProfileScopedID: String]
    private(set) var steps: [ProfileScopedID: [LatestActivityItem]] = [:]

    init(_ activity: [LatestActivityItem], sessions: [SessionSummary]) {
        aliases = Dictionary(
            sessions.compactMap { session -> (ProfileScopedID, String)? in
                guard let profile = session.profileID, let storedID = session.storedSessionID else { return nil }
                return (ProfileScopedID(profileID: profile, resourceID: session.id), storedID)
            }, uniquingKeysWith: { first, _ in first })
        for item in activity {
            let key = ProfileScopedID(profileID: item.profileID, resourceID: item.sessionID)
            guard key.profileID != nil else { continue }
            steps[canonical(key), default: []].append(item)
        }
    }

    func canonical(_ key: ProfileScopedID) -> ProfileScopedID {
        ProfileScopedID(profileID: key.profileID, resourceID: aliases[key] ?? key.resourceID)
    }
}

struct OfficeDeskWorkGroups {
    var attention: [OfficePreviewAgentPresentation] = []
    var working: [OfficePreviewAgentPresentation] = []
    var board: [OfficePreviewAgentPresentation] = []
    var isEmpty: Bool { attention.isEmpty && working.isEmpty && board.isEmpty }

    init(agents: [OfficePreviewAgentPresentation], kanbanCurrent: Bool) {
        for agent in agents {
            switch OfficeAgentStatus(agent: agent, isDataCurrent: kanbanCurrent) {
            case .blocked: attention.append(agent)
            case .working: working.append(agent)
            case .reviewing, .queued: board.append(agent)
            case .idle, .stale: break
            }
        }
    }
}

struct OfficeDeskEvent: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case step, handoff, kanban

        var filterTitle: String {
            switch self {
            case .step: "Session steps"
            case .handoff: "Handoffs"
            case .kanban: "Kanban changes"
            }
        }
    }

    let kind: Kind
    let sourceID: String
    let title: String
    let context: String
    let timestamp: Date
    var id: String { "\(kind.rawValue):\(sourceID)" }

    static func recent(
        activity: [LatestActivityItem], handoffs: [BotActivityRecord],
        tasks: [KanbanTaskSummary], originTitles: [String: String]
    ) -> [Self] {
        let steps = activity.map {
            Self(
                kind: .step, sourceID: $0.id, title: $0.activityName, context: $0.sessionTitle, timestamp: $0.timestamp)
        }
        let transfers = handoffs.filter { !$0.isKanbanReference }.map { record in
            let origin = originTitles[record.originSessionID].map { "\($0) → " } ?? ""
            return Self(
                kind: .handoff, sourceID: record.id, title: record.summary,
                context: "\(origin)\(record.botName) · \(record.state.label)", timestamp: record.updatedAt)
        }
        let board = tasks.compactMap { task -> Self? in
            let labels = [task.latestEventNote, task.latestEventKind?.replacingOccurrences(of: "_", with: " ")]
            guard let timestamp = task.latestEventAt,
                let event = labels.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty })
            else { return nil }
            return Self(
                kind: .kanban, sourceID: "\(task.boardSlug ?? "")/\(task.id)", title: event,
                context: task.title, timestamp: timestamp)
        }
        var seen = Set<String>()
        var counts: [Kind: Int] = [:]
        return (steps + transfers + board).sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp
        }.filter {
            guard counts[$0.kind, default: 0] < 12, seen.insert($0.id).inserted else { return false }
            counts[$0.kind, default: 0] += 1
            return true
        }
    }
}
