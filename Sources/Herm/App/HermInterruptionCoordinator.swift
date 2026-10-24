import Combine
import Foundation

struct HermNotice: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case completion, quota, information, approval, clarification, failure
        var blocking: Bool { [.approval, .clarification, .failure].contains(self) }
        var title: String {
            switch self {
            case .completion: "Work completed"
            case .quota: "Quota changed"
            case .information: "Activity updated"
            case .approval: "Needs your approval"
            case .clarification: "Needs your answer"
            case .failure: "Work could not finish"
            }
        }
    }
    enum Source: String, Codable, Sendable {
        case session, quota, kanban, repository, routine, activity
    }
    let kind: Kind
    let source: Source
    let profileID: String?
    let sourceID: String
    let eventID: String
    var boardSlug: String? = nil
    var createdAt = Date()
    var unavailable = false
    var id: String { "\(kind.rawValue)/\(profileID ?? "")/\(sourceID)/\(eventID)" }

    /// A completion may outlive the visible profile's session inventory. Its
    /// captured owner remains the authority for an explicit, read-only lookup.
    var canCheckCompletedSession: Bool {
        source == .session && kind == .completion && !sourceID.isEmpty
    }

    func completedSession(in sessions: [HermesSession]) -> HermesSession? {
        guard canCheckCompletedSession else { return nil }
        return sessions.first { $0.id == sourceID && $0.profileID == profileID }
            ?? HermesSession(
                id: sourceID, profileID: profileID, title: sourceID,
                preview: "", startedAt: nil, messageCount: 0, source: HermesFeatureIDs.sessionSource)
    }
}

/// One app-boundary policy; only origin references enter its persisted digest.
@MainActor
final class HermInterruptionCoordinator: ObservableObject {
    enum Channel: String { case record, notch, system }
    private struct Saved: Codable {
        let quiet: Bool
        let expiry: Date?
        let entries: [HermNotice]
        let overflow: Int
        let seen: [String]
        let pending: Bool
    }
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let key = "herm.interruptions.v1"
    private var expiryTask: DispatchWorkItem?
    private var seen: [String] = []
    private var admittedChannels = Set<String>()
    @Published private(set) var quiet = false
    @Published private(set) var expiry: Date?
    @Published private(set) var entries: [HermNotice] = []
    @Published private(set) var overflow = 0
    @Published private(set) var pendingDigest = false
    @Published private(set) var digestPresentationRevision = 0
    @Published private(set) var blockingFailure: HermNotice?
    private var failureReferences: [String: HermNotice] = [:]
    var failures: [HermNotice] { Array(failureReferences.values) }
    func recordFailure(_ notice: HermNotice) {
        guard notice.kind == .failure else { return }
        failureReferences["\(notice.profileID ?? "")/\(notice.sourceID)"] = notice
        if blockingFailure != notice { blockingFailure = notice }
    }
    func clearFailure(owner: String, profileID: String?) {
        guard failureReferences.removeValue(forKey: "\(profileID ?? "")/\(owner)") != nil else {
            return
        }
        blockingFailure = failureReferences.values.max { $0.createdAt < $1.createdAt }
    }

    init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        if let data = defaults?.data(forKey: key),
            let saved = try? JSONDecoder().decode(Saved.self, from: data)
        {
            quiet = saved.quiet
            expiry = saved.expiry
            entries = Array(saved.entries.suffix(50)).map { entry in
                var entry = entry
                entry.unavailable = [.session, .kanban, .repository, .routine].contains(entry.source)
                return entry
            }
            overflow = max(0, saved.overflow)
            seen = Array(saved.seen.suffix(500))
            pendingDigest = saved.pending
        }
        expireIfNeeded()
        scheduleExpiry()
    }

    func start(minutes: Int? = 60) {
        quiet = true
        expiry = minutes.map { now().addingTimeInterval(Double($0) * 60) }
        pendingDigest = false
        persist()
        scheduleExpiry()
    }

    func end() {
        guard quiet else { return }
        quiet = false
        expiry = nil
        expiryTask?.cancel()
        pendingDigest = !entries.isEmpty || overflow > 0
        persist()
    }

    func expireIfNeeded() {
        if quiet, let expiry, expiry <= now() { end() }
    }

    func admit(_ notice: HermNotice, channel: Channel) -> Bool {
        expireIfNeeded()
        if quiet, !notice.kind.blocking {
            if !seen.contains(notice.id) {
                seen.append(notice.id)
                if seen.count > 500 { seen.removeFirst(seen.count - 500) }
                entries.append(notice)
                if entries.count > 50 {
                    entries.removeFirst()
                    overflow += 1
                }
                persist()
                DebugLog.write("workflow: ordinary notice suppressed")
            }
            return false
        }
        guard channel != .record else { return false }
        let identity = notice.id + "/" + channel.rawValue
        guard admittedChannels.insert(identity).inserted else { return false }
        if admittedChannels.count > 500 { admittedChannels = [identity] }
        DebugLog.write("workflow: notice admitted on \(channel.rawValue)")
        return true
    }

    func review(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }
    func markUnavailable(_ id: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].unavailable = true
            persist()
        }
    }
    func clearDigest() {
        entries = []
        overflow = 0
        pendingDigest = false
        persist()
    }
    func consumeDigestAnnouncement() {
        guard pendingDigest else { return }
        pendingDigest = false
        digestPresentationRevision += 1
        persist()
    }

    func reconcile(profileID: String?, sessions: [HermesSession], kanban: [KanbanTaskSummary]) {
        let reconciled = entries.map { notice in
            var notice = notice
            if notice.source == .session, notice.profileID == profileID {
                notice.unavailable = !sessions.contains {
                    $0.id == notice.sourceID && $0.profileID == notice.profileID
                }
            } else if notice.source == .kanban, notice.profileID == profileID {
                notice.unavailable = !kanban.contains {
                    $0.id == notice.sourceID && $0.boardSlug == notice.boardSlug
                }
            } else if notice.source == .repository {
                notice.unavailable = !FileManager.default.fileExists(atPath: notice.sourceID)
            }
            return notice
        }
        if reconciled != entries {
            entries = reconciled
            persist()
        }
    }

    func reconcileRoutines(profileID: String?, jobIDs: Set<String>) {
        let updated = entries.map { value in
            var value = value
            if value.source == .routine, value.profileID == profileID {
                value.unavailable = !jobIDs.contains(value.sourceID)
            }
            return value
        }
        if updated != entries {
            entries = updated
            persist()
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard quiet, let expiry else { return }
        let work = DispatchWorkItem { [weak self] in self?.expireIfNeeded() }
        expiryTask = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, expiry.timeIntervalSince(now())), execute: work)
    }
    private func persist() {
        guard let defaults else { return }
        let saved = Saved(
            quiet: quiet, expiry: expiry, entries: entries, overflow: overflow, seen: seen,
            pending: pendingDigest)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }
}
