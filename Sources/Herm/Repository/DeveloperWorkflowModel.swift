import AppKit
import Foundation
import UserNotifications

struct RepositoryReviewBaseline: Equatable {
    let repositoryID: String
    let headRevision: String?
    let fingerprint: String
    let reviewedAt: Date
    let acknowledgedFindingIDs: [String]
    let completeness: RepositoryReviewCompleteness

    init(
        repositoryID: String, headRevision: String?, fingerprint: String, reviewedAt: Date = .now,
        acknowledgedFindingIDs: [String], completeness: RepositoryReviewCompleteness = .partial
    ) {
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
            let timestamp = dictionary["reviewedAt"] as? TimeInterval
        else { return nil }
        self.init(
            repositoryID: repositoryID, headRevision: dictionary["headRevision"] as? String, fingerprint: fingerprint,
            reviewedAt: Date(timeIntervalSince1970: timestamp),
            acknowledgedFindingIDs: dictionary["acknowledgedFindingIDs"] as? [String] ?? [],
            completeness: RepositoryReviewCompleteness(rawValue: dictionary["completeness"] as? String ?? "")
                ?? .partial)
    }

    var dictionary: [String: Any] {
        [
            "repositoryID": repositoryID, "headRevision": headRevision as Any, "fingerprint": fingerprint,
            "reviewedAt": reviewedAt.timeIntervalSince1970, "acknowledgedFindingIDs": acknowledgedFindingIDs,
            "completeness": completeness.rawValue,
        ]
    }
}

enum RepositoryWatchState: Equatable {
    case inactive, watching
    case stale(String)
}

enum RepositoryReviewBaselineStatus: Equatable {
    case none
    case current(Date)
    case stale(Date)
    case partial(Date)

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
    case idle, starting
    case running(String)
    case failed(String)
}

@MainActor
final class DeveloperWorkflowModel: ObservableObject {
    static let shared = DeveloperWorkflowModel()
    var turnBaselines: [String: TurnRepositoryBaseline] = [:]
    private var interruptionCoordinator: HermInterruptionCoordinator?
    @Published private(set) var repository: RepositorySnapshot = .empty
    @Published private(set) var repositoryFingerprint: String?
    @Published private(set) var githubRepository: GitHubRepositoryReference?
    @Published private(set) var githubPullRequests: [GitHubPullRequestSummary] = []
    @Published private(set) var githubError: GitHubCodeHostError?
    @Published private(set) var hasLoadedGitHub = false
    @Published private(set) var isRefreshingGitHub = false
    @Published private(set) var isAuthenticatingGitHub = false
    @Published private(set) var isSigningOutGitHub = false
    @Published private(set) var githubAuthenticationNotice: String?
    @Published private(set) var githubAuthenticationCode: String?
    private var githubAuthenticationProcess: Process?
    private var githubSignOutProcess: Process?
    private var authenticateAfterGitHubSignOut = false
    private var githubAuthenticationOutput = ""
    @Published private(set) var changes: RepositoryChangeSnapshot?
    @Published private(set) var review: RepositoryReviewSnapshot?
    @Published private(set) var worktrees: [RepositoryWorktreeSummary] = []
    @Published private(set) var notices: [RepositoryChangeNotice] = []
    @Published private(set) var watchState: RepositoryWatchState = .inactive
    @Published private(set) var baselineStatus: RepositoryReviewBaselineStatus = .none
    @Published private(set) var handoffState: HandoffWorkflowState = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    @Published private(set) var branches: [String] = []
    @Published private(set) var commits: [RepositoryCommit] = []
    @Published private(set) var commitsError: String?
    @Published private(set) var stashes: [RepositoryStash] = []
    @Published private(set) var stashesError: String?
    @Published private(set) var isMutatingSourceControl = false
    @Published private(set) var sourceControlError: String?
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

    func setActiveRepository(path: String?, preferences: CommandCenterPreferencesStore, control: ControlCenterModel)
        async
    {
        interruptionCoordinator = control.interruptionCoordinator
        preferencesStore = preferences
        DebugLog.writeDiagnostic(
            "repository.workflow set path=\(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil") active=\(activePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil") snapshot=\(repository.path.isEmpty ? "empty" : URL(fileURLWithPath: repository.path).lastPathComponent) git=\(repository.isGitRepository)"
        )
        if path == activePath {
            guard let path,
                repository.path != path || !repository.isGitRepository
            else { return }
            DebugLog.writeDiagnostic(
                "repository.workflow same_path_refresh path=\(URL(fileURLWithPath: path).lastPathComponent)")
            await refresh(preferences: preferences, control: control)
            return
        }
        activePath = path
        commits = []
        stashes = []
        stashesError = nil
        commitsError = nil
        sourceControlError = nil
        generation = UUID()
        review = nil
        reviewedFileIDs = []
        worktrees = []
        branches = []
        guard path != nil else {
            DebugLog.writeDiagnostic("repository.workflow cleared")
            repository = .empty
            repositoryFingerprint = nil
            githubRepository = nil
            githubPullRequests = []
            githubError = nil
            hasLoadedGitHub = false
            changes = nil
            baselineStatus = .none
            isRefreshing = false
            control.setDevelopmentContextProjection(nil)
            syncWatchers(preferences: preferences, control: control)
            return
        }
        await refresh(preferences: preferences, control: control)
        syncWatchers(preferences: preferences, control: control)
    }

    func refresh(preferences: CommandCenterPreferencesStore, control: ControlCenterModel) async {
        preferencesStore = preferences
        guard let path = activePath else { return }
        let token = UUID()
        generation = token
        isRefreshing = true
        error = nil
        async let snapshot = RepositoryService.inspect(path: path)
        async let changes = RepositoryService.changeSnapshot(path: path)
        async let worktrees = RepositoryService.worktrees(path: path)
        async let branches = RepositoryService.branches(path: path)
        async let fingerprint = RepositoryService.fingerprint(path: path)
        async let githubRemote = RepositoryService.githubRemote(path: path)
        async let recentCommits = RepositoryService.recentCommits(path: path)
        async let stashEntries = RepositoryService.stashes(path: path)
        let (
            resolvedSnapshot, resolvedChanges, resolvedWorktrees, resolvedBranches, resolvedFingerprint,
            resolvedGitHubRemote
        ) = await (snapshot, changes, worktrees, branches, fingerprint, githubRemote)
        guard token == generation, path == activePath else { return }
        let (resolvedCommits, resolvedStashes) = await (recentCommits, stashEntries)
        guard token == generation, path == activePath else { return }
        stashes = resolvedStashes ?? []
        stashesError = resolvedStashes == nil ? "Could not refresh stashes. Refresh to try again." : nil
        if let resolvedCommits { commits = resolvedCommits }
        commitsError = resolvedCommits == nil ? "Could not refresh commits. Refresh to try again." : nil
        let githubRepositoryChanged = githubRepository != resolvedGitHubRemote
        repository = resolvedSnapshot
        repositoryFingerprint = resolvedFingerprint
        githubRepository = resolvedGitHubRemote
        self.changes = resolvedChanges
        self.worktrees = resolvedWorktrees
        self.branches = resolvedBranches
        if githubRepositoryChanged {
            githubPullRequests = []
            githubError = nil
            hasLoadedGitHub = false
        }
        DebugLog.writeDiagnostic(
            "repository.workflow refreshed path=\(resolvedSnapshot.path.isEmpty ? "empty" : URL(fileURLWithPath: resolvedSnapshot.path).lastPathComponent) branch=\(resolvedSnapshot.branch) changed=\(resolvedSnapshot.changedFiles) git=\(resolvedSnapshot.isGitRepository)"
        )
        control.setDevelopmentContextProjection(resolvedSnapshot)
        if let resolvedFingerprint { watchedFingerprints[resolvedSnapshot.repositoryID] = resolvedFingerprint }
        isRefreshing = false
        updateBaselineStatus(
            preferences: preferences, repositoryID: resolvedSnapshot.repositoryID, fingerprint: resolvedFingerprint)
        updateWatchState(preferences: preferences)

        // Load GitHub data as part of the repository refresh. Previously the
        // Source Control view could resolve and display the remote while
        // remaining permanently in `.notLoaded` until the user discovered the
        // small refresh icon in the header. Keep the explicit refresh button,
        // but make the first load automatic and surface auth/network errors in
        // the same view.
        if resolvedGitHubRemote != nil && !isMutatingSourceControl {
            await refreshGitHub()
        }
    }

    func refreshGitHub(client: GitHubCodeHostClient = GitHubCodeHostService()) async {
        guard let githubRepository else { return }
        let requestedRepository = githubRepository
        let requestedGeneration = generation
        isRefreshingGitHub = true
        defer { isRefreshingGitHub = false }
        let result = await client.pullRequests(for: requestedRepository)
        guard
            Self.acceptsGitHubRefresh(
                requestedRepository: requestedRepository, currentRepository: githubRepository,
                requestedGeneration: requestedGeneration, currentGeneration: generation)
        else { return }
        switch result {
        case .success(let pullRequests):
            githubPullRequests = pullRequests
            githubError = nil
            hasLoadedGitHub = true
            githubAuthenticationNotice = nil
            githubAuthenticationCode = nil
        case .failure(let error):
            githubError = error
            // A completed device login should never leave its transient
            // notice/code rendered after the follow-up request fails. Keep
            // the error state authoritative so the view can offer a retry.
            if !isAuthenticatingGitHub {
                githubAuthenticationNotice = nil
                githubAuthenticationCode = nil
            }
        }
    }

    /// Starts GitHub CLI's device/browser login from the Dock. The CLI owns
    /// OAuth and its secure credential storage; Dock only waits for completion
    /// and then retries the read-only PR request.
    func authenticateGitHub() {
        guard !isAuthenticatingGitHub, !isSigningOutGitHub else { return }
        isAuthenticatingGitHub = true
        githubAuthenticationNotice = nil
        githubAuthenticationCode = nil
        githubAuthenticationOutput = ""
        guard let executable = githubCLIExecutable else {
            isAuthenticatingGitHub = false
            githubAuthenticationNotice = "GitHub CLI was not found."
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["HOME"] = home
        environment["GH_CONFIG_DIR"] = environment["GH_CONFIG_DIR"] ?? "\(home)/.config/gh"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let output = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.githubAuthenticationProcess != nil else { return }
                self.githubAuthenticationOutput.append(output)
                self.openGitHubDevicePageIfPresent()
            }
        }
        process.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                guard let self, self.githubAuthenticationProcess === completed else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                self.openGitHubDevicePageIfPresent()
                self.githubAuthenticationProcess = nil
                self.isAuthenticatingGitHub = false
                if completed.terminationStatus == 0 {
                    // Drop the pre-auth unauthorized state immediately. The
                    // refresh below will replace it with either available PR
                    // data or a precise network/API error.
                    self.githubError = nil
                    self.hasLoadedGitHub = false
                    self.githubAuthenticationCode = nil
                    self.githubAuthenticationNotice = "GitHub connected. Refreshing pull requests…"
                    Task { await self.refreshGitHub() }
                } else {
                    self.githubAuthenticationNotice = "GitHub sign-in was not completed. Try again when ready."
                }
            }
        }
        do {
            try process.run()
            githubAuthenticationProcess = process
            // `gh auth login --web` waits for browser confirmation. The Dock
            // must stay responsive while that happens; the completion handler
            // performs the refresh once the CLI finishes.
            githubAuthenticationNotice = "Finish signing in in your browser. This panel will refresh automatically."
        } catch {
            isAuthenticatingGitHub = false
            githubAuthenticationNotice = "Could not open GitHub sign-in."
        }
    }

    /// Clears the account cached by GitHub CLI, then starts a clean device
    /// login. This is intentionally explicit: it lets someone switch GitHub
    /// accounts without leaving the Dock or hunting for a terminal command.
    func resetGitHubAuthentication() {
        signOutGitHub(thenAuthenticate: true)
    }

    /// Signs the current GitHub CLI account out while preserving local Git
    /// repository state. The next sign-in can select a different account.
    func signOutGitHub() {
        signOutGitHub(thenAuthenticate: false)
    }

    private func signOutGitHub(thenAuthenticate: Bool) {
        guard !isAuthenticatingGitHub, !isSigningOutGitHub else { return }
        guard let executable = githubCLIExecutable else {
            githubAuthenticationNotice = "GitHub CLI was not found."
            return
        }

        isSigningOutGitHub = true
        authenticateAfterGitHubSignOut = thenAuthenticate
        githubAuthenticationNotice =
            thenAuthenticate ? "Signing out before a clean GitHub sign-in…" : "Signing out of GitHub…"
        githubAuthenticationCode = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "logout", "--hostname", "github.com"]
        process.environment = githubCLIEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                guard let self, self.githubSignOutProcess === completed else { return }
                let shouldAuthenticate = self.authenticateAfterGitHubSignOut
                self.githubSignOutProcess = nil
                self.authenticateAfterGitHubSignOut = false
                self.isSigningOutGitHub = false
                self.githubPullRequests = []
                self.githubError = nil
                self.hasLoadedGitHub = false
                self.githubAuthenticationCode = nil
                self.githubAuthenticationOutput = ""
                if shouldAuthenticate {
                    self.githubAuthenticationNotice = "Opening a clean GitHub sign-in…"
                    self.authenticateGitHub()
                } else {
                    self.githubAuthenticationNotice =
                        completed.terminationStatus == 0 ? "GitHub signed out." : "No GitHub session was stored."
                }
            }
        }
        do {
            try process.run()
            githubSignOutProcess = process
        } catch {
            isSigningOutGitHub = false
            authenticateAfterGitHubSignOut = false
            githubAuthenticationNotice = "Could not sign out of GitHub."
        }
    }

    private var githubCLIExecutable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })
    }

    private var githubCLIEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["HOME"] = home
        environment["GH_CONFIG_DIR"] = environment["GH_CONFIG_DIR"] ?? "\(home)/.config/gh"
        return environment
    }

    private func openGitHubDevicePageIfPresent() {
        let tokens =
            githubAuthenticationOutput
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map(String.init)

        // gh can stream the label and value in separate chunks (and the
        // label may be followed by words such as “in” or “browser”). Search
        // every token for the device-code shape instead of assuming the next
        // token is the value.
        if let candidate =
            tokens
            .map({ $0.trimmingCharacters(in: .punctuationCharacters) })
            .first(where: {
                let parts = $0.split(separator: "-", omittingEmptySubsequences: true)
                // GitHub device codes are exactly four alphanumeric
                // characters, a hyphen, then four more characters. This
                // excludes prose such as “one-time” from being displayed as
                // the code.
                return parts.count == 2
                    && parts.allSatisfy { part in
                        part.count == 4 && part.allSatisfy { $0.isLetter || $0.isNumber }
                    }
            })
        {
            githubAuthenticationCode = candidate
            githubAuthenticationNotice = "Enter this code in the GitHub browser window."
        }

        let candidates =
            githubAuthenticationOutput
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map(String.init)
        guard
            let rawURL = candidates.first(where: {
                ($0.hasPrefix("https://github.com/") || $0.hasPrefix("http://github.com/"))
                    && ($0.contains("/login/device") || $0.contains("/login/oauth"))
            }), let url = URL(string: rawURL.trimmingCharacters(in: .punctuationCharacters))
        else { return }
        ExternalOpen.open(url)
        if githubAuthenticationCode == nil {
            githubAuthenticationNotice = "GitHub sign-in opened in your browser. Finish the device verification there."
        }
    }

    nonisolated static func acceptsGitHubRefresh(
        requestedRepository: GitHubRepositoryReference, currentRepository: GitHubRepositoryReference?,
        requestedGeneration: UUID, currentGeneration: UUID
    ) -> Bool {
        requestedGeneration == currentGeneration && requestedRepository == currentRepository
    }

    var githubIntegrationState: GitHubIntegrationState {
        GitHubIntegrationPresentation.state(
            repository: githubRepository, hasLoaded: hasLoadedGitHub, error: githubError)
    }

    func switchBranch(_ branch: String, preferences: CommandCenterPreferencesStore, control: ControlCenterModel) async
        -> Bool
    {
        guard let path = activePath, repository.isGitRepository, !isMutatingSourceControl else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await RepositoryService.switchBranch(path: path, branch: branch)
        guard result.success else {
            error = result.error
            return false
        }
        await refresh(preferences: preferences, control: control)
        return true
    }

    func applySourceControl(_ action: RepositorySourceControlAction, path: String, refresh: () async -> Void) async
        -> Bool
    {
        guard !isMutatingSourceControl, !isRefreshing, activePath == path, repository.path == path,
            repository.isGitRepository
        else { return false }
        isMutatingSourceControl = true
        sourceControlError = nil
        defer { isMutatingSourceControl = false }
        let failure = await RepositoryService.applySourceControl(action, path: path)
        guard activePath == path else { return failure == nil }
        sourceControlError = failure
        await refresh()
        return failure == nil
    }

    func runReview(preferences: CommandCenterPreferencesStore) async {
        preferencesStore = preferences
        guard let path = activePath else { return }
        let token = UUID()
        generation = token
        let result = await RepositoryService.review(path: path)
        guard token == generation, path == activePath, let result else { return }
        review = result
        reviewedFileIDs = []
        watchedFingerprints[result.repositoryID] = result.fingerprint
        updateBaselineStatus(
            preferences: preferences, repositoryID: result.repositoryID, fingerprint: result.fingerprint)
    }

    var canSaveReviewBaseline: Bool {
        Self.canSaveBaseline(review: review, reviewedFileIDs: reviewedFileIDs)
    }

    static func canSaveBaseline(review: RepositoryReviewSnapshot?, reviewedFileIDs: Set<String>) -> Bool {
        guard let review else { return false }
        return Set(review.files.map(\.id)).isSubset(of: reviewedFileIDs)
    }

    func isReviewed(_ file: RepositoryFileChange) -> Bool { reviewedFileIDs.contains(file.id) }

    func isReviewCovered(_ file: RepositoryFileChange) -> Bool {
        review?.files.contains(where: { $0.id == file.id }) == true
    }

    func toggleReviewed(_ file: RepositoryFileChange) {
        if reviewedFileIDs.contains(file.id) {
            reviewedFileIDs.remove(file.id)
        } else {
            reviewedFileIDs.insert(file.id)
        }
    }

    func saveReviewBaseline(preferences: CommandCenterPreferencesStore, acknowledgedFindingIDs: [String]) {
        guard let review, canSaveReviewBaseline else { return }
        preferences.saveBaseline(
            RepositoryReviewBaseline(
                repositoryID: review.repositoryID, headRevision: review.headRevision, fingerprint: review.fingerprint,
                acknowledgedFindingIDs: acknowledgedFindingIDs, completeness: review.completeness))
        updateBaselineStatus(
            preferences: preferences, repositoryID: review.repositoryID, fingerprint: review.fingerprint)
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
        for task in debounceTasks.values { task.cancel() }
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
                    guard let self, token == self.watchGeneration, self.watchedPaths[repository.id] == repository.path
                    else { return }
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
        let notice = RepositoryChangeNotice(
            repositoryID: id, displayName: URL(fileURLWithPath: path).lastPathComponent,
            changedFiles: snapshot.changedFiles, createdAt: .now)
        notices.removeAll { $0.repositoryID == id }
        notices.insert(notice, at: 0)
        notices = Array(notices.prefix(20))
        if id == repository.repositoryID, let preferencesStore {
            updateBaselineStatus(preferences: preferencesStore, repositoryID: id, fingerprint: fingerprint)
            updateWatchState(preferences: preferencesStore)
        }
        let interruption = HermNotice(
            kind: .information, source: .repository, profileID: nil,
            sourceID: id, eventID: "\(fingerprint):\(notice.createdAt.timeIntervalSince1970)")
        _ = interruptionCoordinator?.admit(interruption, channel: .record)
        if notificationsEnabled, HermesAppRuntime.supportsUserNotifications,
            interruptionCoordinator?.admit(interruption, channel: .system) != false
        {
            let content = UNMutableNotificationContent()
            content.title = "Repository changed"
            content.body = "\(notice.displayName): \(notice.changedFiles) changed files"
            content.userInfo = ["repository_id": id]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "hermes.repository.\(id)", content: content, trigger: nil))
        }
    }

    private func updateBaselineStatus(
        preferences: CommandCenterPreferencesStore?, repositoryID: String, fingerprint: String?
    ) {
        guard let preferences else { return }
        baselineStatus = .make(baseline: preferences.baseline(for: repositoryID), fingerprint: fingerprint)
    }

    private func updateWatchState(preferences: CommandCenterPreferencesStore) {
        guard repository.isGitRepository, preferences.isWatchingRepository(repository.repositoryID) else {
            watchState = .inactive
            return
        }
        switch baselineStatus {
        case .stale: watchState = .stale("Review baseline is stale.")
        default: watchState = .watching
        }
    }

    func handoffPrompt(focus: String, verification: VerificationSummary?, review: RepositoryReviewSnapshot?) -> String {
        let scope = verification?.evidence?.scope ?? "unknown"
        let reviewSummary =
            review.map {
                "\($0.blockerCount) blockers, \($0.warningCount) warnings, \($0.completeness.rawValue) coverage"
            } ?? "not run"
        return """
            Create a concise Markdown handoff for this active Hermes session. Do not edit files, create tasks, commits, branches, or messages. Report unknown information honestly. Include sections: Work completed; Important decisions; Files changed; Verification evidence (scope: \(scope)); Unresolved findings; Running work; Recommended next actions. Local review summary: \(reviewSummary). Focus: \(focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "general handoff" : focus).
            """
    }
}
