import Foundation
import UserNotifications

struct RepositoryReviewBaseline: Equatable {
    let repositoryID: String
    let headRevision: String?
    let fingerprint: String
    let reviewedAt: Date
    let acknowledgedFindingIDs: [String]
    let completeness: RepositoryReviewCompleteness

    init(repositoryID: String, headRevision: String?, fingerprint: String, reviewedAt: Date = .now, acknowledgedFindingIDs: [String], completeness: RepositoryReviewCompleteness = .partial) {
        self.repositoryID = repositoryID
        self.headRevision = headRevision
        self.fingerprint = fingerprint
        self.reviewedAt = reviewedAt
        self.acknowledgedFindingIDs = Array(acknowledgedFindingIDs.prefix(500))
        self.completeness = completeness
    }

    init?(dictionary: [String: Any]) {
        guard let repositoryID = dictionary["repositoryID"] as? String,
              let fingerprint = dictionary["fingerprint"] as? String,
              let timestamp = dictionary["reviewedAt"] as? TimeInterval else { return nil }
        self.init(repositoryID: repositoryID, headRevision: dictionary["headRevision"] as? String, fingerprint: fingerprint, reviewedAt: Date(timeIntervalSince1970: timestamp), acknowledgedFindingIDs: dictionary["acknowledgedFindingIDs"] as? [String] ?? [], completeness: RepositoryReviewCompleteness(rawValue: dictionary["completeness"] as? String ?? "") ?? .partial)
    }

    var dictionary: [String: Any] {
        ["repositoryID": repositoryID, "headRevision": headRevision as Any, "fingerprint": fingerprint, "reviewedAt": reviewedAt.timeIntervalSince1970, "acknowledgedFindingIDs": acknowledgedFindingIDs, "completeness": completeness.rawValue]
    }
}

enum RepositoryWatchState: Equatable {
    case inactive, watching, stale(String)
}

enum RepositoryReviewBaselineStatus: Equatable {
    case none, current(Date), stale(Date), partial(Date)

    static func make(baseline: RepositoryReviewBaseline?, fingerprint: String?) -> RepositoryReviewBaselineStatus {
        guard let baseline else { return .none }
        guard baseline.fingerprint == fingerprint else { return .stale(baseline.reviewedAt) }
        guard baseline.completeness == .complete else { return .partial(baseline.reviewedAt) }
        return .current(baseline.reviewedAt)
    }
}

struct RepositoryChangeNotice: Identifiable, Equatable {
    let repositoryID: String
    let displayName: String
    let changedFiles: Int
    let createdAt: Date
    var id: String { "\(repositoryID):\(Int(createdAt.timeIntervalSince1970))" }
}

enum SessionContextPressure: String, Equatable {
    case normal, warning, critical, unavailable

    static func make(percent: Double?) -> SessionContextPressure {
        guard let percent else { return .unavailable }
        if percent >= 90 { return .critical }
        if percent >= 80 { return .warning }
        return .normal
    }
}

enum HandoffWorkflowState: Equatable {
    case idle, starting, running(String), failed(String)
}

@MainActor
final class DeveloperWorkflowModel: ObservableObject {
    @Published private(set) var repository: RepositorySnapshot = .empty
    @Published private(set) var changes: RepositoryChangeSnapshot?
    @Published private(set) var review: RepositoryReviewSnapshot?
    @Published private(set) var worktrees: [RepositoryWorktreeSummary] = []
    @Published private(set) var notices: [RepositoryChangeNotice] = []
    @Published private(set) var watchState: RepositoryWatchState = .inactive
    @Published private(set) var baselineStatus: RepositoryReviewBaselineStatus = .none
    @Published private(set) var handoffState: HandoffWorkflowState = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private var activePath: String?
    private var generation = UUID()
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var watchGeneration = UUID()
    private var notificationsEnabled = false
    private var watchedPaths: [String: String] = [:]
    private var watchedFingerprints: [String: String] = [:]
    @Published private(set) var reviewedFileIDs = Set<String>()
    private weak var preferencesStore: CommandCenterPreferencesStore?
    private let watcher = RepositoryWatchService()

    init() {
        watcher.onEvent = { [weak self] repositoryID in
            Task { @MainActor in self?.receivedFilesystemEvent(repositoryID: repositoryID) }
        }
    }

    func setActiveRepository(path: String?, preferences: CommandCenterPreferencesStore, control: ControlCenterModel) async {
        preferencesStore = preferences
        guard path != activePath else { return }
        activePath = path
        generation = UUID()
        review = nil
        reviewedFileIDs = []
        worktrees = []
        guard path != nil else {
            repository = .empty; changes = nil; baselineStatus = .none; isRefreshing = false; control.setDevelopmentContextProjection(nil); syncWatchers(preferences: preferences, control: control); return
        }
        await refresh(preferences: preferences, control: control)
        syncWatchers(preferences: preferences, control: control)
    }

    func refresh(preferences: CommandCenterPreferencesStore, control: ControlCenterModel) async {
        preferencesStore = preferences
        guard let path = activePath else { return }
        let token = UUID(); generation = token; isRefreshing = true; error = nil
        async let snapshot = RepositoryService.inspect(path: path)
        async let changes = RepositoryService.changeSnapshot(path: path)
        async let worktrees = RepositoryService.worktrees(path: path)
        async let fingerprint = RepositoryService.fingerprint(path: path)
        let (resolvedSnapshot, resolvedChanges, resolvedWorktrees, resolvedFingerprint) = await (snapshot, changes, worktrees, fingerprint)
        guard token == generation, path == activePath else { return }
        repository = resolvedSnapshot; self.changes = resolvedChanges; self.worktrees = resolvedWorktrees
        control.setDevelopmentContextProjection(resolvedSnapshot)
        if let resolvedFingerprint { watchedFingerprints[resolvedSnapshot.repositoryID] = resolvedFingerprint }
        isRefreshing = false
        updateBaselineStatus(preferences: preferences, repositoryID: resolvedSnapshot.repositoryID, fingerprint: resolvedFingerprint)
        updateWatchState(preferences: preferences)
    }

    func runReview(preferences: CommandCenterPreferencesStore) async {
        preferencesStore = preferences
        guard let path = activePath else { return }
        let token = UUID(); generation = token
        let result = await RepositoryService.review(path: path)
        guard token == generation, path == activePath, let result else { return }
        review = result
        reviewedFileIDs = []
        watchedFingerprints[result.repositoryID] = result.fingerprint
        updateBaselineStatus(preferences: preferences, repositoryID: result.repositoryID, fingerprint: result.fingerprint)
    }

    var canSaveReviewBaseline: Bool {
        Self.canSaveBaseline(review: review, reviewedFileIDs: reviewedFileIDs)
    }

    static func canSaveBaseline(review: RepositoryReviewSnapshot?, reviewedFileIDs: Set<String>) -> Bool {
        guard let review else { return false }
        return Set(review.files.map(\.id)).isSubset(of: reviewedFileIDs)
    }

    func isReviewed(_ file: RepositoryFileChange) -> Bool { reviewedFileIDs.contains(file.id) }

    func isReviewCovered(_ file: RepositoryFileChange) -> Bool { review?.files.contains(where: { $0.id == file.id }) == true }

    func toggleReviewed(_ file: RepositoryFileChange) {
        if reviewedFileIDs.contains(file.id) { reviewedFileIDs.remove(file.id) } else { reviewedFileIDs.insert(file.id) }
    }

    func saveReviewBaseline(preferences: CommandCenterPreferencesStore, acknowledgedFindingIDs: [String]) {
        guard let review, canSaveReviewBaseline else { return }
        preferences.saveBaseline(RepositoryReviewBaseline(repositoryID: review.repositoryID, headRevision: review.headRevision, fingerprint: review.fingerprint, acknowledgedFindingIDs: acknowledgedFindingIDs, completeness: review.completeness))
        updateBaselineStatus(preferences: preferences, repositoryID: review.repositoryID, fingerprint: review.fingerprint)
        updateWatchState(preferences: preferences)
    }

    func toggleWatching(preferences: CommandCenterPreferencesStore, control: ControlCenterModel) {
        guard repository.isGitRepository else { return }
        preferences.toggleWatchingRepository(repository.repositoryID)
        syncWatchers(preferences: preferences, control: control)
    }

    func syncWatchers(preferences: CommandCenterPreferencesStore, control: ControlCenterModel) {
        preferencesStore = preferences
        notificationsEnabled = preferences.repositoryNotificationsEnabled
        var desired = Set(preferences.watchedRepositoryIDs).map { WatchedRepository(id: $0, path: $0) }
        if repository.isGitRepository, preferences.isWatchingRepository(repository.repositoryID) {
            desired.append(WatchedRepository(id: repository.repositoryID, path: repository.path))
        }
        watchGeneration = UUID()
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks = [:]
        watchedPaths = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0.path) })
        watchedFingerprints = watchedFingerprints.filter { watchedPaths[$0.key] != nil }
        watcher.synchronize(Set(desired))
        updateWatchState(preferences: preferences)
        let token = watchGeneration
        for repository in desired where watchedFingerprints[repository.id] == nil {
            Task { [weak self] in
                guard let fingerprint = await RepositoryService.fingerprint(path: repository.path) else { return }
                await MainActor.run {
                    guard let self, token == self.watchGeneration, self.watchedPaths[repository.id] == repository.path else { return }
                    self.watchedFingerprints[repository.id] = fingerprint
                }
            }
        }
    }

    func setRepositoryNotificationsEnabled(_ enabled: Bool) { notificationsEnabled = enabled }

    private func receivedFilesystemEvent(repositoryID id: String) {
        guard watchedPaths[id] != nil else { return }
        let token = watchGeneration
        debounceTasks[id]?.cancel()
        debounceTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            await self.refreshWatchedRepository(id, watchToken: token)
        }
    }

    private func refreshWatchedRepository(_ id: String, watchToken: UUID) async {
        guard let path = watchedPaths[id] else { return }
        let fingerprint = await RepositoryService.fingerprint(path: path)
        guard watchToken == watchGeneration, watchedPaths[id] == path, let fingerprint else { return }
        guard let prior = watchedFingerprints[id] else {
            watchedFingerprints[id] = fingerprint
            return
        }
        guard prior != fingerprint else { return }
        async let snapshotResult = RepositoryService.inspect(path: path)
        async let changesResult = RepositoryService.changeSnapshot(path: path)
        async let reviewResult = RepositoryService.review(path: path)
        let (snapshot, refreshedChanges, refreshedReview) = await (snapshotResult, changesResult, reviewResult)
        guard watchToken == watchGeneration, watchedPaths[id] == path else { return }
        watchedFingerprints[id] = fingerprint
        if id == repository.repositoryID, activePath == path {
            generation = UUID()
            repository = snapshot
            changes = refreshedChanges
            review = refreshedReview
            reviewedFileIDs = []
        }
        let notice = RepositoryChangeNotice(repositoryID: id, displayName: URL(fileURLWithPath: path).lastPathComponent, changedFiles: snapshot.changedFiles, createdAt: .now)
        notices.removeAll { $0.repositoryID == id }
        notices.insert(notice, at: 0)
        notices = Array(notices.prefix(20))
        if id == repository.repositoryID, let preferencesStore {
            updateBaselineStatus(preferences: preferencesStore, repositoryID: id, fingerprint: fingerprint)
            updateWatchState(preferences: preferencesStore)
        }
        if notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Repository changed"
            content.body = "\(notice.displayName): \(notice.changedFiles) changed files"
            content.userInfo = ["repository_id": id]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hermes.repository.\(id)", content: content, trigger: nil))
        }
    }

    private func updateBaselineStatus(preferences: CommandCenterPreferencesStore?, repositoryID: String, fingerprint: String?) {
        guard let preferences else { return }
        baselineStatus = .make(baseline: preferences.baseline(for: repositoryID), fingerprint: fingerprint)
    }

    private func updateWatchState(preferences: CommandCenterPreferencesStore) {
        guard repository.isGitRepository, preferences.isWatchingRepository(repository.repositoryID) else { watchState = .inactive; return }
        switch baselineStatus {
        case .stale: watchState = .stale("Review baseline is stale.")
        default: watchState = .watching
        }
    }

    func handoffPrompt(focus: String, verification: VerificationSummary?, review: RepositoryReviewSnapshot?) -> String {
        let scope = verification?.evidence?.scope ?? "unknown"
        let reviewSummary = review.map { "\($0.blockerCount) blockers, \($0.warningCount) warnings, \($0.completeness.rawValue) coverage" } ?? "not run"
        return """
        Create a concise Markdown handoff for this active Hermes session. Do not edit files, create tasks, commits, branches, or messages. Report unknown information honestly. Include sections: Work completed; Important decisions; Files changed; Verification evidence (scope: \(scope)); Unresolved findings; Running work; Recommended next actions. Local review summary: \(reviewSummary). Focus: \(focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "general handoff" : focus).
        """
    }
}
