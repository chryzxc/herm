import Foundation

struct WatchedPullRequest: Codable, Identifiable, Equatable {
    let repository: GitHubRepositoryReference
    let number: Int
    var id: String { "\(repository.id)#\(number)" }
    var url: URL { repository.webURL.appendingPathComponent("pull/\(number)") }
}

struct PullRequestWatchSnapshot: Equatable {
    var merged: Bool
    var conflicted: Bool
    var failedChecks: Set<String>
    var lastReviewID: Int
    var lastCommentID: Int
    func changes(from previous: Self) -> [String] {
        var result: [String] = []
        if merged && !previous.merged { result.append("Merged") }
        if conflicted && !previous.conflicted { result.append("Merge conflicts") }
        if !failedChecks.subtracting(previous.failedChecks).isEmpty { result.append("Checks failed") }
        if lastReviewID > previous.lastReviewID { result.append("New review") }
        if lastCommentID > previous.lastCommentID { result.append("New comment") }
        return result
    }
}

/// Passive provider polling only. This store never submits an agent request.
@MainActor
final class PullRequestWatchStore: ObservableObject {
    static let shared = PullRequestWatchStore()
    @Published private(set) var watched: [WatchedPullRequest]
    @Published private(set) var updates: [String: [String]] = [:]
    @Published private(set) var error: String?
    private var snapshots: [String: PullRequestWatchSnapshot] = [:]
    private let defaults: UserDefaults
    private let client: GitHubClient
    private var task: Task<Void, Never>?
    private var workspaceVisible = false
    private var retryNotBefore: Date?
    var onNotice: ((WatchedPullRequest, [String]) -> Void)?
    init(defaults: UserDefaults = .standard, client: GitHubClient = GitHubClient()) {
        self.defaults = defaults
        self.client = client
        watched =
            defaults.data(forKey: "herm.pr-watches.v1").flatMap {
                try? JSONDecoder().decode([WatchedPullRequest].self, from: $0)
            } ?? []
    }
    func contains(_ record: PullRequestRecord) -> Bool {
        watched.contains { $0.repository == record.repository && $0.number == record.number }
    }
    func toggle(_ record: PullRequestRecord) {
        let reference = WatchedPullRequest(repository: record.repository, number: record.number)
        if watched.contains(reference) {
            watched.removeAll { $0.id == reference.id }
            snapshots[reference.id] = nil
            updates[reference.id] = nil
        } else {
            watched.append(reference)
        }
        save()
        restart()
    }
    func start() { if task == nil { restart() } }
    func setWorkspaceVisible(_ visible: Bool) {
        guard workspaceVisible != visible else { return }
        workspaceVisible = visible
        restart()
    }
    func stop() {
        task?.cancel()
        task = nil
    }
    private func save() {
        if let data = try? JSONEncoder().encode(watched) { defaults.set(data, forKey: "herm.pr-watches.v1") }
    }
    private func restart() {
        stop()
        guard !watched.isEmpty else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let retryNotBefore, retryNotBefore > .now {
                    do { try await Task.sleep(for: .seconds(retryNotBefore.timeIntervalSinceNow)) } catch { return }
                }
                let result = await poll()
                guard !Task.isCancelled else { return }
                if result > 120 { retryNotBefore = Date().addingTimeInterval(result) } else { retryNotBefore = nil }
                let delay = max(result, workspaceVisible ? 120 : 300)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    func poll() async -> Double {
        for reference in watched {
            guard !Task.isCancelled else { return 120 }
            do {
                let path = reference.repository.apiRepositoryPath
                guard let pr = try await client.request(path + "/pulls/\(reference.number)") as? [String: Any],
                    let head = pr["head"] as? [String: Any], let sha = head["sha"] as? String,
                    GitHubConflictService.validRevision(sha)
                else { throw GitHubRequestError.malformed }
                let checks = try await client.pages(path + "/commits/\(sha)/check-runs", key: "check_runs")
                let status = try await client.request(path + "/commits/\(sha)/status") as? [String: Any]
                let reviews = try await client.pages(path + "/pulls/\(reference.number)/reviews")
                let comments = try await client.pages(path + "/issues/\(reference.number)/comments")
                guard !checks.coverage.partial, !reviews.coverage.partial, !comments.coverage.partial else {
                    throw GitHubRequestError.unavailable
                }
                var failed = Set(
                    checks.rows.filter {
                        ["failure", "timed_out", "action_required", "cancelled", "startup_failure"].contains(
                            $0["conclusion"] as? String ?? "")
                    }.compactMap { $0["name"] as? String })
                if ["failure", "error"].contains(status?["state"] as? String ?? "") { failed.insert("Commit status") }
                let snapshot = PullRequestWatchSnapshot(
                    merged: pr["merged"] as? Bool == true,
                    conflicted: pr["mergeable"] as? Bool == false, failedChecks: failed,
                    lastReviewID: reviews.rows.compactMap { $0["id"] as? Int }.max() ?? 0,
                    lastCommentID: comments.rows.compactMap { $0["id"] as? Int }.max() ?? 0)
                guard watched.contains(reference), !Task.isCancelled else { continue }
                if let previous = snapshots[reference.id] {
                    let changes = snapshot.changes(from: previous)
                    if !changes.isEmpty {
                        updates[reference.id] = changes
                        onNotice?(reference, changes)
                    }
                }
                snapshots[reference.id] = snapshot
                error = nil
                if snapshot.merged {
                    watched.removeAll { $0.id == reference.id }
                    save()
                }
            } catch GitHubRequestError.rateLimited(let retry) {
                error = "PR watching is waiting for GitHub’s rate limit."
                return max(120, retry?.timeIntervalSinceNow ?? 120)
            } catch {
                if Task.isCancelled { return 120 }
                self.error = DockModel.safeUserDiagnostic(error.localizedDescription)
                return 240
            }
        }
        return 120
    }
}
