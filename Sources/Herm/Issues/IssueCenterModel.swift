import Foundation
import SwiftUI

@MainActor
final class IssueCenterModel: ObservableObject {
    let api: GitHubIssueCenterAPI
    private let repositoryRemote: @Sendable (String) async -> GitHubRepositoryReference?
    @Published var records: [GitHubIssueRecord] = [] {
        didSet {
            guard hasLoaded else { return }
            let previous = Dictionary(oldValue.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
            for row in records where row.id != selectedIssueID {
                if let old = previous[row.id] ?? nil, let updated = row.updatedAt, updated > old { changedIDs.insert(row.id) }
            }
        }
    }
    @Published private(set) var changedIDs = Set<String>()
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false
    @Published var viewerLogin: String?
    @Published var selectedIssueID: String? {
        didSet {
            if oldValue != selectedIssueID { detailErrorMessage = nil }; if let selectedIssueID { changedIDs.remove(selectedIssueID) }
        }
    }
    @Published private(set) var detailByID: [String: GitHubIssueRecord] = [:]
    @Published private(set) var loadingDetailID: String?
    @Published private(set) var detailErrorMessage: String?
    @Published var filter: GitHubIssueFilter = .all
    @Published var query = ""
    @Published var repositoryScope: String?
    @Published var browsing = GitHubBrowseOptions()
    @Published private(set) var coverage: String?
    @Published private(set) var repositories: [GitHubRepositoryReference] = []
    private var generation = UUID()
    private var detailNeedsRefresh = Set<String>()
    private var stateVersions: [String: UUID] = [:]
    private var conversations: [String: GitHubConversationModel] = [:]

    init(
        api: GitHubIssueCenterAPI = GitHubIssueCenterAPI(),
        repositoryRemote: @escaping @Sendable (String) async -> GitHubRepositoryReference? = { path in
            await RepositoryService.githubRemote(path: path)
        }
    ) {
        self.api = api
        self.repositoryRemote = repositoryRemote
    }

    func conversation(for record: GitHubIssueRecord) -> GitHubConversationModel {
        if let model = conversations[record.id] { return model }
        if conversations.count >= 32, let key = conversations.first(where: { $0.value.draft.isEmpty && $0.key != selectedIssueID })?.key { conversations[key] = nil }
        let model = GitHubConversationModel(reference: record.reference, client: api.client)
        conversations[record.id] = model
        return model
    }
    var selected: GitHubIssueRecord? { records.first { $0.id == selectedIssueID } }
    var hasActiveFilters: Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || repositoryScope != nil
    }
    var visible: [GitHubIssueRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { matches($0, filter: filter, needle: needle) }.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? .distantPast
            let right = rhs.updatedAt ?? .distantPast
            if browsing.sort == .newest { return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast) }
            if left != right { return browsing.sort == .oldest ? left < right : left > right }
            return lhs.id < rhs.id
        }
    }

    /// Visible issues grouped by repository, ordered by each group's most
    /// recently updated issue.
    var visibleGroups: [(repository: String, issues: [GitHubIssueRecord])] {
        var order: [String] = []
        var groups: [String: [GitHubIssueRecord]] = [:]
        for issue in visible {
            if groups[issue.repository.id] == nil { order.append(issue.repository.id) }
            groups[issue.repository.id, default: []].append(issue)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    func count(for filter: GitHubIssueFilter) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { matches($0, filter: filter, needle: needle) }.count
    }

    private func matches(_ issue: GitHubIssueRecord, filter: GitHubIssueFilter, needle: String) -> Bool {
        guard repositoryScope == nil || repositoryScope == issue.repository.id else { return false }
        let matchesFilter: Bool
        switch filter {
        case .all: matchesFilter = true
        case .authored: matchesFilter = viewerLogin.map { issue.author.caseInsensitiveCompare($0) == .orderedSame } ?? false
        case .assigned: matchesFilter = viewerLogin.map { viewer in issue.assignees.contains { assignee in assignee.caseInsensitiveCompare(viewer) == .orderedSame } } ?? false
        }
        guard matchesFilter else { return false }
        guard !needle.isEmpty else { return true }
        return [issue.title, issue.repository.id, issue.author, issue.body, issue.labels.joined(separator: " "), issue.assignees.joined(separator: " "), "#\(issue.number)"].joined(separator: " ").lowercased().contains(needle)
    }

    func refresh(projects: [ProjectSummary]) async {
        guard !Task.isCancelled, !isRefreshing else { return }
        let token = UUID(); generation = token; isRefreshing = true; errorMessage = nil
        defer { if token == generation { isRefreshing = false } }
        let paths = Array(Set(projects.filter(\.isRenderableProject).map(\.name))).filter { !$0.isEmpty }
        async let viewerLookup = api.viewer()
        let resolved = await RepositoryService.githubRemotes(paths: paths, resolve: repositoryRemote)
        let remotes = Dictionary(resolved.map { ($0.1.id, $0.0) }, uniquingKeysWith: { first, _ in first })
        let viewerResult = await viewerLookup
        guard token == generation, !Task.isCancelled else { return }
        guard case .success(let viewer) = viewerResult else {
            viewerLogin = nil
            errorMessage = hasLoaded ? "Using last known GitHub issues. Refresh to retry." : "GitHub issues are unavailable. Check your sign-in or try again."
            repairSelection()
            return
        }
        viewerLogin = viewer
        repositories = Array(Set(resolved.map { $0.1 } + records.map(\.repository))).sorted { $0.id < $1.id }
        if browsing.usesCustomQuery {
            do {
                let page = try await api.searchPage(browsing.query(kind: .issue, viewer: viewer), localPaths: remotes)
                guard token == generation, !Task.isCancelled else { return }
                records = page.items; detailNeedsRefresh.formUnion(detailByID.keys); coverage = page.coverage.label; hasLoaded = true; repairSelection()
            } catch { if token == generation { errorMessage = error.localizedDescription } }
            return
        }
        let result: Result<GitHubPage<GitHubIssueRecord>, Error>
        do { result = .success(try await api.workPage(viewer: viewer, localPaths: remotes)) } catch { result = .failure(error) }
        guard token == generation, !Task.isCancelled else { return }
        switch result {
        case .success(let page):
            let issues = page.items; coverage = page.coverage.label
            records = issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            detailNeedsRefresh.formUnion(detailByID.keys)
            loadingDetailID = nil
            hasLoaded = true
            errorMessage = nil
        case .failure: errorMessage = hasLoaded ? "Using last known GitHub issues. Refresh to retry." : "GitHub issues are unavailable. Check your sign-in or try again."
        }
        repairSelection()
    }

    func open(_ reference: GitHubItemReference) async {
        guard reference.kind == .issue else { return }
        cancelLoads()
        hasLoaded = true
        let token = generation
        do {
            let record = try await api.resolve(reference, localPaths: Dictionary(records.map { ($0.repository.id, $0.localPath) }, uniquingKeysWith: { a, _ in a }))
            guard token == generation, !Task.isCancelled else { return }
            browsing.state = .all; resetFilters()
            records.removeAll { $0.id == record.id }; records.insert(record, at: 0); selectedIssueID = record.id
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelLoads() {
        generation = UUID()
        if isRefreshing { isRefreshing = false }
        if loadingDetailID != nil { loadingDetailID = nil }
    }

    func loadSelectedDetail(force: Bool = false) async {
        guard !Task.isCancelled, !isRefreshing, let issue = selected, (force || detailNeedsRefresh.contains(issue.id) || detailByID[issue.id] == nil) else { return }
        let token = generation
        let stateVersion = stateVersions[issue.id]
        loadingDetailID = issue.id
        detailErrorMessage = nil
        defer {
            if token == generation, loadingDetailID == issue.id { loadingDetailID = nil }
        }
        let detail = await api.detail(issue)
        guard token == generation, !Task.isCancelled, selectedIssueID == issue.id, stateVersion == stateVersions[issue.id] else { return }
        detailNeedsRefresh.remove(issue.id)
        if let detail {
            if let currentDate = detailByID[issue.id]?.updatedAt, (detail.updatedAt ?? .distantPast) < currentDate { return }
            detailByID[issue.id] = detail
            if let index = records.firstIndex(where: { $0.id == issue.id }) { records[index] = detail }
        } else {
            detailErrorMessage = "Could not refresh full issue details. Showing the latest available summary."
        }
    }

    func refreshSelectedDetail() async {
        guard let id = selectedIssueID else { return }
        await loadSelectedDetail(force: true)
        if let record = detailByID[id] ?? selected { await conversation(for: record).refresh() }
    }

    func applyIssueState(_ updated: GitHubIssueRecord) {
        stateVersions[updated.id] = UUID()
        var result = detailByID[updated.id] ?? records.first(where: { $0.id == updated.id }) ?? updated
        result.state = updated.state; result.updatedAt = updated.updatedAt ?? result.updatedAt
        detailByID[result.id] = result
        if (result.isOpen && browsing.state == .closed) || (!result.isOpen && browsing.state == .open) {
            records.removeAll { $0.id == result.id }; repairSelection()
        } else if let index = records.firstIndex(where: { $0.id == result.id }) {
            records[index] = result
        }
    }

    func resetFilters() {
        filter = .all
        query = ""
        repositoryScope = nil
        repairSelection()
    }

    func repairSelection() { if !visible.contains(where: { $0.id == selectedIssueID }) { selectedIssueID = visible.first?.id } }
}

