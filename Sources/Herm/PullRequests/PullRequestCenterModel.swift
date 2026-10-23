import Combine
import Foundation
import SwiftUI

@MainActor
final class PullRequestCenterModel: ObservableObject {
    let api: PullRequestCenterAPI
    let details: PullRequestDetailStore
    private var detailChanges: AnyCancellable?
    private var recordChanges: AnyCancellable?
    private let mutationExecutor: any PullRequestMutationExecuting
    private var statusVersions: [String: UUID] = [:]
    private var summaryTasks: [String: Task<PullRequestRecord?, Never>] = [:]
    private(set) var records: [PullRequestRecord] {
        get { storedRecords }
        set { storedRecords = newValue.map { $0.retainingMergedState(from: details.records[$0.id]) } }
    }
    @Published private var storedRecords: [PullRequestRecord] = [] {
        didSet {
            guard hasLoaded else { return }
            let previous = Dictionary(oldValue.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
            for row in records where row.id != selectedID {
                if let old = previous[row.id] ?? nil, let updated = row.updatedAt, updated > old {
                    changedIDs.insert(row.id)
                }
            }
        }
    }
    @Published private(set) var changedIDs = Set<String>()
    var filesByID: [String: [PullRequestFile]] {
        get { details.files }
        set { details.files = newValue }
    }
    var commentsByID: [String: [PullRequestComment]] {
        get { details.comments }
        set { details.comments = newValue }
    }
    var commitsByID: [String: [PullRequestCommit]] {
        get { details.commits }
        set { details.commits = newValue }
    }
    var eventsByID: [String: [PullRequestEvent]] {
        get { details.events }
        set { details.events = newValue }
    }
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadingDetailIDs = Set<String>()
    @Published private(set) var isPostingComment = false
    @Published private(set) var isUpdatingStatus = false
    @Published private(set) var updatingStatusID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var failedRepositories: [String] = []
    @Published private(set) var viewerLogin: String?
    @Published var filter: PullRequestFilter = .all
    @Published var query = ""
    var commentDrafts: [String: String] {
        get { details.drafts }
        set { details.drafts = newValue }
    }
    @Published var selectedID: String? { didSet { if let selectedID { changedIDs.remove(selectedID) } } }
    @Published var browsing = GitHubBrowseOptions()
    @Published private(set) var coverage: String?
    @Published private(set) var repositories: [GitHubRepositoryReference] = []
    private var generation = UUID()
    private var detailNeedsRefresh = Set<String>()

    func review(for record: PullRequestRecord) -> PullRequestReviewModel {
        if let existing = details.reviews[record.id] { return existing }
        let model = PullRequestReviewModel(client: api.client)
        details.reviews[record.id] = model
        return model
    }

    init(
        api: PullRequestCenterAPI = PullRequestCenterAPI(), mutationExecutor: (any PullRequestMutationExecuting)? = nil,
        details: PullRequestDetailStore? = nil
    ) {
        self.api = api
        self.details = details ?? PullRequestDetailStore()
        self.mutationExecutor = mutationExecutor ?? api
        detailChanges = self.details.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        recordChanges = self.details.$records.sink { [weak self] values in
            guard let self else { return }
            for index in self.records.indices {
                if var updated = values[self.records[index].id],
                    (updated.refreshedAt ?? .distantPast) >= (self.records[index].refreshedAt ?? .distantPast)
                {
                    updated.localPath = self.records[index].localPath
                    if updated != self.records[index] { self.records[index] = updated }
                }
            }
        }
    }

    var isLoadingDetail: Bool { !loadingDetailIDs.isEmpty }
    func isLoadingDetail(for id: String) -> Bool { loadingDetailIDs.contains(id) }
    var selected: PullRequestRecord? {
        guard let row = records.first(where: { $0.id == selectedID }) else { return nil }
        if var cached = details.records[row.id],
            cached.mergedAt != nil
                || ((cached.updatedAt ?? .distantPast) >= (row.updatedAt ?? .distantPast)
                    && (row.headRevision == nil || cached.headRevision == row.headRevision))
        {
            cached.localPath = row.localPath
            return cached
        }
        return row
    }
    var isInitialLoad: Bool { isRefreshing && records.isEmpty }

    @discardableResult
    func beginDetailLoad(for id: String) -> Bool {
        guard !id.isEmpty, !loadingDetailIDs.contains(id) else { return false }
        loadingDetailIDs.insert(id)
        return true
    }

    func finishDetailLoad(for id: String) {
        loadingDetailIDs.remove(id)
    }
    var visible: [PullRequestRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .merged: matchesFilter = item.mergedAt != nil
            case _ where item.mergedAt != nil && browsing.state == .open: matchesFilter = false
            case .all: matchesFilter = true
            case .authored:
                matchesFilter = viewerLogin.map { item.author.caseInsensitiveCompare($0) == .orderedSame } ?? false
            case .reviewing:
                matchesFilter =
                    viewerLogin.map { login in
                        item.requestedReviewers.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
                    } ?? false
            }
            guard matchesFilter else { return false }
            guard !needle.isEmpty else { return true }
            return [
                item.title, item.repository.id, item.author, item.body, item.labels.joined(separator: " "),
                item.headBranch, item.baseBranch, "#\(item.number)",
            ].joined(separator: " ").lowercased().contains(needle)
        }.sorted { lhs, rhs in
            switch browsing.sort {
            case .updated: (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            case .oldest: (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
            case .newest: (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
            }
        }
    }

    func refresh(projects: [ProjectSummary]) async {
        guard !Task.isCancelled, !isRefreshing else { return }
        let paths = Array(Set(projects.filter(\.isRenderableProject).map(\.name))).filter { !$0.isEmpty }
        let token = UUID()
        generation = token
        isRefreshing = true
        errorMessage = nil
        failedRepositories = []
        defer { if token == generation { isRefreshing = false } }
        resetSummaryCache()
        loadingDetailIDs.removeAll()
        // Resolve the viewer while local git remotes are being read.
        async let viewerLookup = api.viewer()
        let remotes = await RepositoryService.githubRemotes(paths: paths)
        let viewer = await viewerLookup
        guard token == generation, !Task.isCancelled else { return }
        let localPaths = Dictionary(remotes.map { ($0.1.id, $0.0) }, uniquingKeysWith: { first, _ in first })
        viewerLogin = viewer
        repositories = Array(Set(remotes.map { $0.1 } + records.map(\.repository))).sorted { $0.id < $1.id }
        if browsing.usesCustomQuery {
            do {
                let page = try await api.searchPage(
                    browsing.query(kind: .pullRequest, viewer: viewer), localPaths: localPaths)
                guard token == generation, !Task.isCancelled else { return }
                records = page.items
                coverage = page.coverage.label
                hasLoaded = true
                repairSelection()
            } catch { if token == generation { errorMessage = error.localizedDescription } }
            return
        }

        // The PR center is account-scoped, rather than scoped to whichever
        // Hermes project happens to be selected. Search GitHub for authored
        // and requested-review PRs so repositories that are not attached
        // locally still appear in the workspace.
        if let viewer {
            let global: Result<GitHubPage<PullRequestRecord>, Error>
            do { global = .success(try await api.workPage(viewer: viewer, localPaths: localPaths)) } catch {
                global = .failure(error)
            }
            guard token == generation, !Task.isCancelled else { return }
            switch global {
            case .success(let page):
                let rows = page.items
                coverage = page.coverage.label
                // Row metadata is loaded as the lazy list reveals each PR.
                records = rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                if let selectedID { detailNeedsRefresh.insert(selectedID) }
                failedRepositories = []
                errorMessage = nil
                repairSelection()
                hasLoaded = true
                return
            case .failure:
                // Keep the attached-repository path as a useful fallback if
                // GitHub search is temporarily rate-limited or unavailable.
                errorMessage = "GitHub account search failed. Showing attached repositories."
            }
        } else if remotes.isEmpty {
            errorMessage =
                paths.isEmpty
                ? "No Hermes projects are attached and GitHub sign-in is unavailable."
                : "GitHub sign-in is required to load your pull requests."
            return
        }

        guard !remotes.isEmpty else {
            errorMessage = "No attached repositories were available and GitHub account search failed."
            return
        }
        let results = await withTaskGroup(
            of: Result<[PullRequestRecord], PullRequestCenterFailure>.self,
            returning: [Result<[PullRequestRecord], PullRequestCenterFailure>].self
        ) { group in
            for (path, remote) in remotes {
                group.addTask { [api] in await api.index(repository: remote, localPath: path) }
            }
            var output: [Result<[PullRequestRecord], PullRequestCenterFailure>] = []
            for await result in group { output.append(result) }
            return output
        }
        guard token == generation, !Task.isCancelled else { return }
        var fresh: [PullRequestRecord] = []
        var failures: [String] = []
        for result in results {
            switch result {
            case .success(let rows): fresh += rows
            case .failure(let failure): failures.append(failure.repository)
            }
        }
        if !fresh.isEmpty {
            records = fresh.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            if let selectedID { detailNeedsRefresh.insert(selectedID) }
        }
        failedRepositories = failures
        if fresh.isEmpty && !failures.isEmpty {
            errorMessage = "GitHub could not load pull requests. Check your GitHub sign-in or try again."
        }
        if failures.isEmpty { hasLoaded = true }
        if fresh.isEmpty && failures.isEmpty {
            records = []
        }
        repairSelection()
    }

    /// Session-scoped refresh: loads only the pull requests of one local
    /// repository path, without the account-wide GitHub search that the
    /// pull-request workspace performs.
    func refreshScoped(repositoryPath: String) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        isRefreshing = true
        errorMessage = nil
        failedRepositories = []
        defer { if token == generation { isRefreshing = false } }
        resetSummaryCache()
        loadingDetailIDs.removeAll()
        let remote = await RepositoryService.githubRemote(path: repositoryPath)
        guard token == generation, !Task.isCancelled else { return }
        guard let remote else {
            records = []
            selectedID = nil
            errorMessage = "This session's repository has no GitHub remote."
            return
        }
        async let viewerLookup = api.viewer()
        async let indexLookup = api.index(repository: remote, localPath: repositoryPath)
        let since = Date.now.addingTimeInterval(-14 * 86_400).formatted(.iso8601.year().month().day())
        async let mergedLookup = try? api.searchPage(
            "is:pr is:merged repo:\(remote.id) merged:>=\(since)", localPaths: [remote.id: repositoryPath])
        let (viewer, result, merged) = await (viewerLookup, indexLookup, mergedLookup)
        guard token == generation, !Task.isCancelled else { return }
        viewerLogin = viewer
        switch result {
        case .success(let rows):
            hasLoaded = true
            let unique = Dictionary(
                (rows + (merged?.items ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            records = unique.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            failedRepositories = []
            errorMessage =
                merged == nil
                ? "Open results loaded; recent merged history is unavailable."
                : (merged?.coverage.partial == true ? merged?.coverage.label : nil)
        case .failure:
            failedRepositories = [remote.id]
            if records.isEmpty {
                errorMessage = "GitHub could not load pull requests for \(remote.id). Check your sign-in and try again."
            }
        }
        repairSelection()
    }

    @discardableResult
    func open(_ reference: GitHubItemReference) async -> Bool {
        guard reference.kind == .pullRequest else { return false }
        cancelLoads()
        hasLoaded = true
        let token = generation
        do {
            let record = try await api.resolve(
                reference, localPath: records.first { $0.repository == reference.repository }?.localPath ?? "")
            guard token == generation, !Task.isCancelled else { return false }
            browsing.state = .all
            filter = .all
            query = ""
            records.removeAll { $0.id == record.id }
            records.insert(record, at: 0)
            selectedID = record.id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func commentDraft(for id: String) -> Binding<String> {
        Binding(get: { self.commentDrafts[id] ?? "" }, set: { self.commentDrafts[id] = $0 })
    }

    func repairSelection() { if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id } }

    func cancelLoads() {
        generation = UUID()
        resetSummaryCache()
        if !loadingDetailIDs.isEmpty { loadingDetailIDs.removeAll() }
        if isRefreshing { isRefreshing = false }
    }

    private func resetSummaryCache() {
        for task in summaryTasks.values { task.cancel() }
        summaryTasks.removeAll()
    }

    @discardableResult
    func loadSummary(for record: PullRequestRecord) async -> PullRequestRecord? {
        guard !Task.isCancelled, !isRefreshing else { return nil }
        if let task = summaryTasks[record.id], !task.isCancelled {
            return await task.value?.retainingMergedState(from: details.records[record.id])
        }
        let token = generation
        let statusVersion = statusVersions[record.id]
        guard !isUpdatingStatus else { return nil }
        let api = api
        let task = Task { await api.detail(record) }
        summaryTasks[record.id] = task
        let updated = await task.value?.retainingMergedState(from: details.records[record.id])
        guard token == generation, !task.isCancelled, statusVersion == statusVersions[record.id] else { return nil }
        if let updated, let current = details.records[record.id],
            let currentDate = current.updatedAt, (updated.updatedAt ?? .distantPast) < currentDate
        {
            return current
        }
        if let updated { details.records[record.id] = updated }
        if let updated, let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = updated
        }
        return updated
    }

    func filesAreCurrent(for record: PullRequestRecord) -> Bool {
        guard let revision = record.diffRevision else { return false }
        return details.fileRevisions[record.id] == revision
    }

    func loadSelectedDetail() async {
        guard !Task.isCancelled, !isRefreshing, let selected,
            filesByID[selected.id] == nil || !filesAreCurrent(for: selected) || detailNeedsRefresh.contains(selected.id)
        else { return }
        guard beginDetailLoad(for: selected.id) else { return }
        let token = generation
        defer { if token == generation { finishDetailLoad(for: selected.id) } }
        let snapshot = await loadSummary(for: selected)
        guard token == generation, !Task.isCancelled else { return }
        async let files = api.files(selected)
        async let comments = api.comments(selected)
        async let commits = api.commits(selected)
        async let events = api.events(selected)
        let (loadedFiles, loadedComments, loadedCommits, loadedEvents) = await (files, comments, commits, events)
        let verified = try? await api.resolve(
            GitHubItemReference(repository: selected.repository, number: selected.number, kind: .pullRequest),
            localPath: selected.localPath)
        guard token == generation, !Task.isCancelled else { return }
        // `nil` means this selection has never attempted a detail load. Store
        // an empty terminal value on failure so selection changes cannot leave
        // the detail task eligible for an immediate retry loop. The code-tab
        // projection still distinguishes an unavailable response from a
        // genuine empty pull request using `changedFiles`.
        detailNeedsRefresh.remove(selected.id)
        let revisionMatches = snapshot?.diffRevision != nil && snapshot?.diffRevision == verified?.diffRevision
        if revisionMatches, let loadedFiles {
            filesByID[selected.id] = loadedFiles
            details.fileRevisions[selected.id] = snapshot?.diffRevision
        } else {
            filesByID[selected.id] = filesByID[selected.id] ?? []
            details.fileRevisions[selected.id] = nil
            errorMessage =
                "Diff revisions could not be verified. Available files may be outdated; refresh before reviewing."
        }
        if let loadedComments { commentsByID[selected.id] = loadedComments }
        if let loadedCommits { commitsByID[selected.id] = loadedCommits }
        if let loadedEvents { eventsByID[selected.id] = loadedEvents }
        if let count = selected.changedFiles, let loadedFiles, loadedFiles.count < count {
            errorMessage =
                "Showing \(loadedFiles.count) of \(count) changed files. GitHub limits file results; open the pull request on GitHub for complete coverage."
        }
        if loadedFiles == nil || loadedComments == nil || loadedCommits == nil || loadedEvents == nil {
            errorMessage =
                "Some pull request sections could not be refreshed. Showing available data; refresh this pull request to retry."
        }
    }

    func invalidateSelectedDetail() {
        guard let selected else { return }
        summaryTasks.removeValue(forKey: selected.id)?.cancel()
        detailNeedsRefresh.insert(selected.id)
    }

    func refreshSelectedDetail() async {
        invalidateSelectedDetail()
        await loadSelectedDetail()
    }

    func addComment(_ body: String, to record: PullRequestRecord) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 10_000, !isPostingComment else { return false }
        isPostingComment = true
        defer { isPostingComment = false }
        guard let comment = await mutationExecutor.postComment(trimmed, on: record) else {
            errorMessage = "GitHub could not add the comment. Check your sign-in and try again."
            return false
        }
        if !commentsByID[record.id, default: []].contains(where: { $0.id == comment.id }) {
            commentsByID[record.id, default: []].append(comment)
        }
        if commentDrafts[record.id]?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            commentDrafts[record.id] = nil
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].comments += 1 }
        return true
    }

    func applyLandingSnapshot(_ snapshot: GitHubLandingSnapshot, for record: PullRequestRecord) {
        guard snapshot.state == "MERGED", let mergedAt = snapshot.mergedAt,
            snapshot.id == record.nodeID, snapshot.head == record.headRevision
        else { return }
        statusVersions[record.id] = UUID()
        summaryTasks.removeValue(forKey: record.id)?.cancel()
        var updated = details.records[record.id] ?? records.first(where: { $0.id == record.id }) ?? record
        updated.mergedAt = mergedAt
        updated.state = "closed"
        updated.isDraft = false
        updated.updatedAt = snapshot.updatedAt ?? mergedAt
        updated.refreshedAt = .now
        details.records[record.id] = updated
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = updated }
    }

    func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> Bool {
        guard !isUpdatingStatus else { return false }
        isUpdatingStatus = true
        updatingStatusID = record.id
        errorMessage = nil
        statusVersions[record.id] = UUID()
        summaryTasks.removeValue(forKey: record.id)?.cancel()
        defer {
            isUpdatingStatus = false
            updatingStatusID = nil
        }
        guard let response = await mutationExecutor.updateStatus(status, for: record) else {
            errorMessage = "GitHub could not update this pull request status. Check your sign-in and try again."
            return false
        }
        summaryTasks.removeValue(forKey: record.id)?.cancel()
        let updated = response.retainingMergedState(from: details.records[record.id])
        details.records[record.id] = updated
        if (updated.state == "closed" && browsing.state == .open)
            || (updated.state == "open" && browsing.state == .closed)
        {
            records.removeAll { $0.id == record.id }
            filesByID[record.id] = nil
            commentsByID[record.id] = nil
            commitsByID[record.id] = nil
            eventsByID[record.id] = nil
            repairSelection()
        } else if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = updated
        }
        return true
    }
}
