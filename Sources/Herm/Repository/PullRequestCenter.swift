import Foundation
import SwiftUI

enum PullRequestFilter: String, CaseIterable, Identifiable {
    case all = "All", reviewing = "Reviewing", authored = "Authored"
    var id: Self { self }
}

final class PullRequestChatLinkStore: ObservableObject {
    private let defaults = UserDefaults.standard
    private let key = "hermes.pull-request-chat-links"
    func sessionID(for pullRequestID: String) -> String? { (defaults.dictionary(forKey: key) as? [String: String])?[pullRequestID] }
    func save(sessionID: String, for pullRequestID: String) {
        var links = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        links[pullRequestID] = sessionID
        defaults.set(links, forKey: key)
    }
    func remove(pullRequestID: String) {
        var links = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        links.removeValue(forKey: pullRequestID)
        defaults.set(links, forKey: key)
    }
}

struct PullRequestFile: Identifiable, Equatable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?
    let webURL: URL?
    var id: String { path }
}

enum PullRequestFilesProjection: Equatable {
    case loading
    case unavailable
    case empty
    case loaded([PullRequestFile])

    static func state(files: [PullRequestFile]?, isLoading: Bool, expectedFileCount: Int?) -> Self {
        guard let files else { return isLoading ? .loading : .unavailable }
        guard files.isEmpty else { return .loaded(files) }
        // An empty `/files` response is authoritative only when the PR detail
        // agrees that there are no changed files. A canceled or incomplete
        // request must remain retryable instead of being cached as empty.
        return expectedFileCount == 0 ? .empty : .unavailable
    }
}

struct PullRequestComment: Identifiable, Equatable, Sendable {
    let id: String
    let body: String
    let author: String
    let authorAvatarURL: URL?
    let createdAt: Date?
    let webURL: URL?
}

struct PullRequestCommit: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
    let author: String
    let authorAvatarURL: URL?
    let committedAt: Date?
    let webURL: URL?
}

enum PullRequestStatus: String, CaseIterable, Identifiable, Sendable {
    case draft = "Draft"
    case readyForReview = "Ready for review"
    case closed = "Closed"
    var id: Self { self }
}

enum PullRequestDiffMode: String, CaseIterable, Identifiable {
    case unified, split
    var id: Self { self }
    var label: String { self == .unified ? "Unified diff" : "Split diff" }
}

final class PullRequestReviewPreferenceStore: ObservableObject {
    private let defaults: UserDefaults
    private let prefix = "hermes.pull-request-review."
    @Published var showsFileTree: Bool { didSet { persist() } }
    @Published var diffMode: PullRequestDiffMode { didSet { persist() } }
    @Published var wordWrap: Bool { didSet { persist() } }
    @Published var richPreview: Bool { didSet { persist() } }
    @Published var wordDiffs: Bool { didSet { persist() } }
    @Published var expandedFileIDs: Set<String> { didSet { persist() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsFileTree = defaults.object(forKey: prefix + "file-tree") as? Bool ?? false
        diffMode = PullRequestDiffMode(rawValue: defaults.string(forKey: prefix + "diff-mode") ?? "unified") ?? .unified
        wordWrap = defaults.object(forKey: prefix + "word-wrap") as? Bool ?? false
        richPreview = defaults.object(forKey: prefix + "rich-preview") as? Bool ?? false
        wordDiffs = defaults.object(forKey: prefix + "word-diffs") as? Bool ?? false
        expandedFileIDs = Set(defaults.stringArray(forKey: prefix + "expanded-files") ?? [])
    }

    func toggleExpanded(_ fileID: String) {
        if expandedFileIDs.contains(fileID) { expandedFileIDs.remove(fileID) } else { expandedFileIDs.insert(fileID) }
    }

    func setAllExpanded(_ fileIDs: Set<String>) {
        expandedFileIDs = expandedFileIDs.isSuperset(of: fileIDs) ? [] : fileIDs
    }

    private func persist() {
        defaults.set(showsFileTree, forKey: prefix + "file-tree")
        defaults.set(diffMode.rawValue, forKey: prefix + "diff-mode")
        defaults.set(wordWrap, forKey: prefix + "word-wrap")
        defaults.set(richPreview, forKey: prefix + "rich-preview")
        defaults.set(wordDiffs, forKey: prefix + "word-diffs")
        defaults.set(Array(expandedFileIDs).sorted(), forKey: prefix + "expanded-files")
    }
}

struct PullRequestFileTreeNode: Identifiable, Equatable {
    let id: String
    let title: String
    let depth: Int
    let isDirectory: Bool
    let fileID: String?
}

enum PullRequestFileTreeBuilder {
    static func make(files: [PullRequestFile]) -> [PullRequestFileTreeNode] {
        var directories = Set<String>()
        var nodes: [(path: String, title: String, depth: Int, isDirectory: Bool, fileID: String?)] = []
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            if components.count > 1 {
                for index in 1..<(components.count) {
                    directories.insert(components.prefix(index).joined(separator: "/"))
                }
            }
        }
        let allPaths = Set(files.map(\.path)).union(directories)
        for path in allPaths.sorted() {
            let parts = path.split(separator: "/").map(String.init)
            let directory = directories.contains(path)
            nodes.append((path, parts.last ?? path, max(0, parts.count - 1), directory, directory ? nil : path))
        }
        return nodes.sorted { lhs, rhs in
            if lhs.path == rhs.path { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }.map { PullRequestFileTreeNode(id: $0.path, title: $0.title, depth: $0.depth, isDirectory: $0.isDirectory, fileID: $0.fileID) }
    }
}

enum PullRequestDiffLineKind: Equatable {
    case context, addition, deletion, hunk, metadata
}

struct PullRequestDiffLine: Identifiable, Equatable {
    let index: Int
    let text: String
    let kind: PullRequestDiffLineKind
    var id: Int { index }

    init(index: Int, text: String) {
        self.index = index
        self.text = text
        if text.hasPrefix("@@") { kind = .hunk }
        else if text.hasPrefix("+++") || text.hasPrefix("---") { kind = .metadata }
        else if text.hasPrefix("+") { kind = .addition }
        else if text.hasPrefix("-") { kind = .deletion }
        else { kind = .context }
    }
}

struct PullRequestDiffSplitRow: Identifiable, Equatable {
    let id: Int
    let left: PullRequestDiffLine?
    let right: PullRequestDiffLine?
}

enum PullRequestDiffPresentation {
    static func lines(_ patch: String) -> [PullRequestDiffLine] {
        patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { PullRequestDiffLine(index: $0.offset, text: String($0.element)) }
    }

    static func splitRows(_ lines: [PullRequestDiffLine]) -> [PullRequestDiffSplitRow] {
        var rows: [PullRequestDiffSplitRow] = []
        var cursor = 0
        while cursor < lines.count {
            let line = lines[cursor]
            if line.kind == .deletion {
                var deletions: [PullRequestDiffLine] = []
                while cursor < lines.count, lines[cursor].kind == .deletion { deletions.append(lines[cursor]); cursor += 1 }
                var additions: [PullRequestDiffLine] = []
                while cursor < lines.count, lines[cursor].kind == .addition { additions.append(lines[cursor]); cursor += 1 }
                for index in 0..<max(deletions.count, additions.count) {
                    rows.append(PullRequestDiffSplitRow(id: rows.count, left: index < deletions.count ? deletions[index] : nil, right: index < additions.count ? additions[index] : nil))
                }
            } else if line.kind == .addition {
                rows.append(PullRequestDiffSplitRow(id: rows.count, left: nil, right: line))
                cursor += 1
            } else {
                rows.append(PullRequestDiffSplitRow(id: rows.count, left: line, right: line.kind == .context || line.kind == .metadata ? line : nil))
                cursor += 1
            }
        }
        return rows
    }
}

/// Keeps patch parsing out of SwiftUI's scrolling/layout pass. A patch is
/// immutable for the lifetime of a loaded pull request, so its presentation
/// rows are safe to reuse until the selected pull request changes.
@MainActor
final class PullRequestDiffPresentationCache: ObservableObject {
    private var rowsByPatch: [String: [PullRequestDiffSplitRow]] = [:]

    func rows(for patch: String) -> [PullRequestDiffSplitRow] {
        if let rows = rowsByPatch[patch] { return rows }
        let rows = PullRequestDiffPresentation.splitRows(PullRequestDiffPresentation.lines(patch))
        rowsByPatch[patch] = rows
        return rows
    }

    func removeAll() {
        rowsByPatch.removeAll(keepingCapacity: true)
    }
}

private struct PullRequestReviewToolbarIcon: View {
    let name: Ph
    let accessibilityLabel: String
    var isSelected = false
    var tooltip: String? = nil
    @State private var isHovered = false

    var body: some View {
        DockIcon(name, size: 14, color: isSelected || isHovered ? Color.dockPrimaryText : Color.dockSecondaryText)
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                .fill(isSelected ? Color.dockSurface4 : (isHovered ? Color.dockSurface4.opacity(0.72) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .onHover { isHovered = $0 }
        .help(tooltip ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Git pull-request glyph with a check-status dot.
struct PullRequestBranchIcon: View {
    enum Status { case success, failure, draft, neutral }
    let status: Status
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DockIcon(.gitPullRequest, size: 17, color: iconColor)
            if status == .success || status == .failure {
                Circle().fill(status == .success ? Color.dockSuccess : Color.dockDestructive).frame(width: 6, height: 6).overlay(Circle().stroke(Color.dockSurface2, lineWidth: 1.1)).offset(x: 1, y: 1)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var iconColor: Color {
        switch status {
        case .success: return Color.dockSuccess
        case .failure: return Color.dockDestructive
        case .draft: return Color.dockMetadataText
        case .neutral: return Color.dockSecondaryText
        }
    }
}

struct PullRequestRecord: Identifiable, Equatable {
    let repository: GitHubRepositoryReference
    let localPath: String
    let number: Int
    var title: String
    var body: String
    var author: String
    var authorAvatarURL: URL?
    var headBranch: String
    var baseBranch: String
    var updatedAt: Date?
    var isDraft: Bool
    var webURL: URL?
    var requestedReviewers: [String]
    var comments: Int
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var checks: [GitHubCheckSummary]
    var reviews: [GitHubReviewSummary]
    var id: String { "github:\(repository.id)#\(number)" }
    /// PR identifiers are not quantities: never localize them with grouping
    /// separators (for example, render `4878`, never `4,878`).
    var displayNumber: String { String(number) }

    var readinessLabel: String {
        if isDraft { return "DRAFT" }
        if checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return "CHECKS FAILED" }
        if checks.contains(where: { $0.status.lowercased() != "completed" }) { return "CHECKS RUNNING" }
        return checks.isEmpty ? "OPEN" : "READY"
    }
}

struct PullRequestCenterFailure: Error { let repository: String }

@MainActor
final class PullRequestCenterModel: ObservableObject {
    private let mutationExecutor: any PullRequestMutationExecuting
    @Published private(set) var records: [PullRequestRecord] = []
    @Published private(set) var filesByID: [String: [PullRequestFile]] = [:]
    @Published private(set) var commentsByID: [String: [PullRequestComment]] = [:]
    @Published private(set) var commitsByID: [String: [PullRequestCommit]] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadingDetailIDs = Set<String>()
    @Published private(set) var isPostingComment = false
    @Published private(set) var isUpdatingStatus = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var failedRepositories: [String] = []
    @Published private(set) var viewerLogin: String?
    @Published var filter: PullRequestFilter = .all
    @Published var query = ""
    @Published var selectedID: String?
    private var generation = UUID()

    init(mutationExecutor: any PullRequestMutationExecuting = PullRequestCenterAPI()) {
        self.mutationExecutor = mutationExecutor
    }

    var isLoadingDetail: Bool { !loadingDetailIDs.isEmpty }
    func isLoadingDetail(for id: String) -> Bool { loadingDetailIDs.contains(id) }
    var selected: PullRequestRecord? { records.first { $0.id == selectedID } }
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
            case .all: matchesFilter = true
            case .authored: matchesFilter = viewerLogin.map { item.author.caseInsensitiveCompare($0) == .orderedSame } ?? false
            case .reviewing: matchesFilter = viewerLogin.map { login in item.requestedReviewers.contains { $0.caseInsensitiveCompare(login) == .orderedSame } } ?? false
            }
            guard matchesFilter else { return false }
            guard !needle.isEmpty else { return true }
            return [item.title, item.repository.id, item.author, item.headBranch, item.baseBranch, "#\(item.number)"].joined(separator: " ").lowercased().contains(needle)
        }
    }

    func refresh(projects: [ProjectSummary]) async {
        let paths = Array(Set(projects.filter(\.isRenderableProject).map(\.name))).filter { !$0.isEmpty }
        let token = UUID(); generation = token; isRefreshing = true; errorMessage = nil; failedRepositories = []
        let remotes = await withTaskGroup(of: (String, GitHubRepositoryReference?).self, returning: [(String, GitHubRepositoryReference)].self) { group in
            for path in paths { group.addTask { (path, await RepositoryService.githubRemote(path: path)) } }
            var unique: [String: (String, GitHubRepositoryReference)] = [:]
            for await (path, remote) in group where remote != nil { if let remote, unique[remote.id] == nil { unique[remote.id] = (path, remote) } }
            return Array(unique.values)
        }
        guard token == generation else { return }
        let api = PullRequestCenterAPI()
        let localPaths = Dictionary(uniqueKeysWithValues: remotes.map { ($0.1.id, $0.0) })
        let viewer = await api.viewer()
        viewerLogin = viewer

        // The PR center is account-scoped, rather than scoped to whichever
        // Hermes project happens to be selected. Search GitHub for authored
        // and requested-review PRs so repositories that are not attached
        // locally still appear in the workspace.
        if let viewer {
            let global = await api.searchPullRequests(viewerLogin: viewer, localPaths: localPaths)
            guard token == generation else { return }
            switch global {
            case .success(let rows):
                // GitHub search items omit head/base refs. Resolve those
                // details in bounded batches so the list does not show
                // "unknown" until a row is clicked.
                let enriched = await api.enrichIndex(rows)
                guard token == generation else { return }
                records = enriched.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                filesByID = [:]; commentsByID = [:]; commitsByID = [:]
                failedRepositories = []
                errorMessage = nil
                isRefreshing = false
                repairSelection()
                return
            case .failure:
                // Keep the attached-repository path as a useful fallback if
                // GitHub search is temporarily rate-limited or unavailable.
                errorMessage = "GitHub account search failed. Showing attached repositories."
            }
        } else if remotes.isEmpty {
            records = []
            selectedID = nil
            errorMessage = paths.isEmpty ? "No Hermes projects are attached and GitHub sign-in is unavailable." : "GitHub sign-in is required to load your pull requests."
            isRefreshing = false
            return
        }

        guard !remotes.isEmpty else {
            records = []
            selectedID = nil
            errorMessage = "No attached repositories were available and GitHub account search failed."
            isRefreshing = false
            return
        }
        let results = await withTaskGroup(of: Result<[PullRequestRecord], PullRequestCenterFailure>.self, returning: [Result<[PullRequestRecord], PullRequestCenterFailure>].self) { group in
            for (path, remote) in remotes {
                group.addTask { await api.index(repository: remote, localPath: path) }
            }
            var output: [Result<[PullRequestRecord], PullRequestCenterFailure>] = []
            for await result in group { output.append(result) }
            return output
        }
        guard token == generation else { return }
        var fresh: [PullRequestRecord] = []
        var failures: [String] = []
        for result in results {
            switch result { case .success(let rows): fresh += rows; case .failure(let failure): failures.append(failure.repository) }
        }
        if !fresh.isEmpty { records = fresh.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }; filesByID = [:]; commentsByID = [:]; commitsByID = [:] }
        failedRepositories = failures
        if fresh.isEmpty && !failures.isEmpty { errorMessage = "GitHub could not load pull requests. Check your GitHub sign-in or try again." }
        isRefreshing = false
        repairSelection()
    }

    /// Session-scoped refresh: loads only the pull requests of one local
    /// repository path, without the account-wide GitHub search that the
    /// pull-request workspace performs.
    func refreshScoped(repositoryPath: String) async {
        let token = UUID(); generation = token; isRefreshing = true; errorMessage = nil; failedRepositories = []
        let remote = await RepositoryService.githubRemote(path: repositoryPath)
        guard token == generation else { return }
        guard let remote else {
            records = []
            selectedID = nil
            filesByID = [:]; commentsByID = [:]; commitsByID = [:]
            errorMessage = "This session's repository has no GitHub remote."
            isRefreshing = false
            return
        }
        let api = PullRequestCenterAPI()
        let viewer = await api.viewer()
        guard token == generation else { return }
        viewerLogin = viewer
        let result = await api.index(repository: remote, localPath: repositoryPath)
        guard token == generation else { return }
        switch result {
        case .success(let rows):
            records = rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            filesByID = [:]; commentsByID = [:]; commitsByID = [:]
            failedRepositories = []
            errorMessage = nil
        case .failure:
            failedRepositories = [remote.id]
            if records.isEmpty { errorMessage = "GitHub could not load pull requests for \(remote.id). Check your sign-in and try again." }
        }
        isRefreshing = false
        repairSelection()
    }

    func repairSelection() { if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id } }

    func loadSelectedDetail() async {
        guard let selected,
              filesByID[selected.id] == nil
        else { return }
        guard beginDetailLoad(for: selected.id) else { return }
        defer { finishDetailLoad(for: selected.id) }
        let api = PullRequestCenterAPI()
        async let detail = api.detail(selected)
        async let files = api.files(selected)
        async let comments = api.comments(selected)
        async let commits = api.commits(selected)
        let (updated, loadedFiles, loadedComments, loadedCommits) = await (detail, files, comments, commits)
        guard !Task.isCancelled else { return }
        if let updated, let index = records.firstIndex(where: { $0.id == selected.id }) { records[index] = updated }
        if let loadedFiles { filesByID[selected.id] = loadedFiles }
        commentsByID[selected.id] = loadedComments ?? []
        commitsByID[selected.id] = loadedCommits ?? []
    }

    func refreshSelectedDetail() async {
        guard let selected else { return }
        filesByID[selected.id] = nil
        commentsByID[selected.id] = nil
        commitsByID[selected.id] = nil
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
        commentsByID[record.id, default: []].append(comment)
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].comments += 1 }
        return true
    }

    func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> Bool {
        guard !isUpdatingStatus else { return false }
        if status == .draft {
            // GitHub's REST API exposes the Draft → Ready transition, but
            // does not provide a REST endpoint to return a ready PR to Draft.
            return record.isDraft
        }
        isUpdatingStatus = true
        defer { isUpdatingStatus = false }
        guard let updated = await mutationExecutor.updateStatus(status, for: record) else {
            errorMessage = "GitHub could not update this pull request status. Check your sign-in and try again."
            return false
        }
        if status == .closed {
            records.removeAll { $0.id == record.id }
            filesByID[record.id] = nil
            commentsByID[record.id] = nil
            commitsByID[record.id] = nil
            repairSelection()
        } else if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = updated
        }
        return true
    }
}

/// A mutation intent is inert until the detail surface explicitly confirms it.
/// No GitHub write should be reachable from a row/menu action directly.
enum PullRequestMutationRequest: Identifiable, Equatable {
    case comment(record: PullRequestRecord, body: String)
    case status(record: PullRequestRecord, status: PullRequestStatus)

    var id: String {
        switch self {
        case let .comment(record, body): return "comment:\(record.id):\(body)"
        case let .status(record, status): return "status:\(record.id):\(status.rawValue)"
        }
    }
}

@MainActor
final class PullRequestMutationCoordinator: ObservableObject {
    @Published private(set) var pending: PullRequestMutationRequest?

    func requestComment(_ body: String, for record: PullRequestRecord) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending = .comment(record: record, body: trimmed)
    }

    func requestStatus(_ status: PullRequestStatus, for record: PullRequestRecord) {
        pending = .status(record: record, status: status)
    }

    func cancel() {
        pending = nil
    }

    func confirm(using center: PullRequestCenterModel) async -> Bool {
        guard let pending else { return false }
        defer { self.pending = nil }
        switch pending {
        case let .comment(record, body):
            return await center.addComment(body, to: record)
        case let .status(record, status):
            return await center.updateStatus(status, for: record)
        }
    }
}

struct PullRequestRowView: View {
    let pullRequest: PullRequestRecord
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                PullRequestBranchIcon(status: iconStatus).padding(.top, -1)
                (Text("#\(pullRequest.displayNumber) ").foregroundStyle(Color.dockMetadataText) + Text(pullRequest.title).foregroundStyle(Color.dockPrimaryText))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            Text("\(pullRequest.repository.id) · \(pullRequest.headBranch)")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text(pullRequest.readinessLabel)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(pullRequest.isDraft ? Color.dockMetadataText : Color.dockAccent)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill((pullRequest.isDraft ? Color.dockSurface4 : Color.dockAccent.opacity(0.16))))
                Spacer()
                if let adds = pullRequest.additions, let dels = pullRequest.deletions {
                    HStack(spacing: 8) {
                        Text("+\(adds)").foregroundStyle(Color.dockSuccess)
                        Text("−\(dels)").foregroundStyle(Color.dockDestructive)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous).fill(isSelected ? Color.dockAccent.opacity(0.16) : (isHovered ? Color.dockSurface4.opacity(0.5) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var iconStatus: PullRequestBranchIcon.Status {
        guard !pullRequest.isDraft else { return .draft }
        if pullRequest.checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return .failure }
        return .success
    }
}

private struct PullRequestDiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Color.dockSuccess) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Color.dockDestructive) }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .fixedSize()
    }
}

private struct PullRequestFileTreeRow: View {
    let node: PullRequestFileTreeNode
    let icon: Ph
    let iconColor: Color
    let file: PullRequestFile?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                DockIcon(icon, size: 13, color: node.isDirectory ? Color.dockMetadataText : iconColor)
                    .frame(width: 14, height: 14)
                Text(node.title)
                    .font(.system(size: 12, weight: node.isDirectory ? .regular : .medium))
                    .foregroundStyle(isSelected ? Color.dockPrimaryText : (node.isDirectory ? Color.dockMetadataText : Color.dockSecondaryText))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let file { PullRequestDiffStat(additions: file.additions, deletions: file.deletions) }
            }
            .padding(.leading, CGFloat(node.depth) * 12 + 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                    .fill(isSelected ? Color.dockAccent.opacity(0.16) : (isHovered && !node.isDirectory ? Color.dockSurface4.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(node.isDirectory)
        .onHover { isHovered = $0 }
        .help(node.id)
    }
}

struct PullRequestDiffLineView: View {
    let line: PullRequestDiffLine
    var counterpart: String? = nil
    var wordDiffsEnabled = false

    var body: some View {
        let tint: Color = line.kind == .addition ? .dockSuccess : (line.kind == .deletion ? .dockDestructive : (line.kind == .hunk ? .dockAccent : .dockSecondaryText))
        let fill: Color = line.kind == .addition ? Color.dockSuccess.opacity(0.13) : (line.kind == .deletion ? Color.dockDestructive.opacity(0.13) : (line.kind == .hunk ? Color.dockAccent.opacity(0.08) : Color.dockSurface2))
        let content = (line.kind == .addition || line.kind == .deletion) ? String(line.text.dropFirst()) : line.text
        let counterpartContent = counterpart.map { value in
            guard let first = value.first, first == "+" || first == "-" else { return value }
            return String(value.dropFirst())
        }
        HStack(spacing: 0) {
            if line.kind == .addition || line.kind == .deletion { Text(String(line.text.prefix(1))).foregroundStyle(tint).fontWeight(.bold) }
            diffWords(content, counterpart: counterpartContent, tint: tint)
        }
        .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
        .padding(.horizontal, 10)
        .background(fill)
        .overlay(alignment: .leading) { if line.kind != .context { tint.frame(width: 2) } }
    }

    @ViewBuilder
    private func diffWords(_ content: String, counterpart: String?, tint: Color) -> some View {
        if wordDiffsEnabled, let counterpart, content.count < 500 {
            let otherWords = Set(counterpart.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
            let words = content.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            HStack(spacing: 0) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    Text(word)
                        .foregroundStyle(Color.dockSecondaryText)
                        .background(otherWords.contains(word.trimmingCharacters(in: .whitespacesAndNewlines)) ? Color.clear : tint.opacity(0.28))
                    if word != words.last { Text(" ") }
                }
            }
        } else {
            Text(content).foregroundStyle(Color.dockSecondaryText)
        }
    }
}

struct PullRequestDetailView: View {
    @ObservedObject var center: PullRequestCenterModel
    let onOpenChat: (PullRequestRecord) -> Void

    @State private var detailTab = 0
    @StateObject private var reviewPreferences = PullRequestReviewPreferenceStore()
    @State private var selectedFileID: String?
    @State private var sourceDiffFileIDs: Set<String> = []
    @State private var descriptionExpanded = false
    @State private var checksExpanded = true
    @State private var activityExpanded = true
    @State private var commentDraft = ""
    @StateObject private var diffPresentationCache = PullRequestDiffPresentationCache()
    @StateObject private var mutationCoordinator = PullRequestMutationCoordinator()

    private var isLoadingSelectedDetail: Bool {
        guard let selected = center.selected else { return false }
        return center.isLoadingDetail(for: selected.id) && center.filesByID[selected.id] == nil
    }

    var body: some View {
        detailPane
            .task(id: center.selectedID) {
                guard center.selectedID != nil else { return }
                await center.loadSelectedDetail()
            }
            .onChange(of: center.selectedID) { _, _ in
                selectedFileID = nil
                sourceDiffFileIDs.removeAll()
                diffPresentationCache.removeAll()
                descriptionExpanded = false
                checksExpanded = true
                activityExpanded = true
                commentDraft = ""
                mutationCoordinator.cancel()
            }
            .confirmationDialog(
                "Confirm GitHub change?",
                isPresented: Binding(
                    get: { mutationCoordinator.pending != nil },
                    set: { if !$0 { mutationCoordinator.cancel() } }
                ),
                presenting: mutationCoordinator.pending
            ) { request in
                switch request {
                case .comment:
                    Button("Post comment") {
                        Task {
                            if await mutationCoordinator.confirm(using: center) { commentDraft = "" }
                        }
                    }
                case let .status(_, status):
                    Button(status == .closed ? "Close pull request" : "Mark ready for review", role: status == .closed ? .destructive : nil) {
                        Task { _ = await mutationCoordinator.confirm(using: center) }
                    }
                }
                Button("Cancel", role: .cancel) { mutationCoordinator.cancel() }
            } message: { request in
                mutationConfirmationMessage(request)
            }
    }

    private func mutationConfirmationMessage(_ request: PullRequestMutationRequest) -> Text {
        switch request {
        case let .comment(record, body):
            return Text("Post this comment to \(record.repository.id) pull request #\(record.number)?\n\n\(body)")
        case let .status(record, status):
            if status == .closed {
                return Text("This will close pull request #\(record.number) in \(record.repository.id).")
            }
            return Text("This will mark pull request #\(record.number) in \(record.repository.id) ready for review.")
        }
    }

    @ViewBuilder private var detailPane: some View {
        if center.isInitialLoad || isLoadingSelectedDetail {
            detailLoadingPane
        } else if let pr = center.selected { VStack(alignment: .leading, spacing: 0) {
        detailHeader(pr)
        if detailTab == 0 {
            ScrollView { summary(pr).padding(.horizontal, 24) }
        } else {
            code(pr).padding(.horizontal, 16)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else { VStack(spacing: 12) { DockIcon(.gitPullRequest, size: 28, color: Color.dockMetadataText); Text(center.isRefreshing ? "Loading pull requests…" : "Select a pull request").font(.system(size: 15, weight: .medium)) }.foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var detailLoadingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RepositoryShimmerBlock(width: 72, height: 22, cornerRadius: 7)
                RepositoryShimmerBlock(width: 48, height: 22, cornerRadius: 7)
                Spacer()
                RepositoryShimmerBlock(width: 88, height: 28, cornerRadius: 7)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading pull request")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    RepositoryShimmerBlock(width: nil, height: 28, cornerRadius: 7)
                    RepositoryShimmerBlock(width: 390, height: 28, cornerRadius: 7)
                    HStack(spacing: 10) {
                        RepositoryShimmerBlock(width: 32, height: 32, cornerRadius: 16)
                        RepositoryShimmerBlock(width: 126, height: 12, cornerRadius: 4)
                    }
                    RepositoryShimmerBlock(width: nil, height: 1, cornerRadius: 0)
                    ForEach(0..<5, id: \.self) { index in
                        HStack(spacing: 14) {
                            RepositoryShimmerBlock(width: 88, height: 11, cornerRadius: 4)
                            RepositoryShimmerBlock(width: index.isMultiple(of: 2) ? 236 : 176, height: 11, cornerRadius: 4)
                        }
                    }
                    RepositoryShimmerBlock(width: nil, height: 1, cornerRadius: 0)
                    RepositoryShimmerBlock(width: 112, height: 15, cornerRadius: 5)
                    RepositoryShimmerBlock(width: nil, height: 82, cornerRadius: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading pull request")
    }

    private func detailHeader(_ pr: PullRequestRecord) -> some View {
        let fileIDs = Set((center.filesByID[pr.id] ?? []).map(\.id))
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                detailTabButton("Summary", selected: detailTab == 0) { detailTab = 0 }
                detailTabButton("Code", selected: detailTab == 1) { detailTab = 1 }
                Spacer()
                HStack(spacing: 6) {
                    if let url = pr.webURL {
                        GitHubLinkButton(
                            destination: url,
                            accessibilityLabel: "Open pull request on GitHub"
                        )
                        Divider().frame(height: 16)
                    }
                    Button("Open chat") { onOpenChat(pr) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).fill(Color.dockSurface4))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if detailTab == 1 {
                HStack(spacing: 10) {
                    Text(pr.headBranch)
                        .lineLimit(1)
                    DockIcon(.arrowRight, size: 14, color: Color.dockMetadataText)
                    Text(pr.baseBranch)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    codeToolbar(fileIDs: fileIDs)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
                .padding(.horizontal, 16)
                .frame(height: 62)
                .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
        .background(Color.dockCanvas)
    }
    private func summary(_ pr: PullRequestRecord) -> some View { VStack(alignment: .leading, spacing: 0) {
        Text(pr.title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.dockPrimaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 26)

        HStack(spacing: 10) {
            authorAvatar(pr)
            Text(pr.author).font(.system(size: 13, weight: .medium))
            if let updatedAt = pr.updatedAt {
                Text("•")
                Text(pullRequestAge(updatedAt))
            }
        }
        .foregroundStyle(Color.dockMetadataText)
        .padding(.top, 12)
        .padding(.bottom, 22)

        VStack(alignment: .leading, spacing: 12) {
            summaryDetailRow(icon: .gitBranch, title: "Branch") {
                HStack(spacing: 8) {
                    Text(pr.headBranch).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    DockIcon(.arrowRight, size: 13, color: Color.dockMetadataText)
                    Text(pr.baseBranch).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    if let additions = pr.additions { Text("+\(additions)").foregroundStyle(Color.dockSuccess).fixedSize(horizontal: true, vertical: false) }
                    if let deletions = pr.deletions { Text("−\(deletions)").foregroundStyle(Color.dockDestructive).fixedSize(horizontal: true, vertical: false) }
                }
            }
            summaryDetailRow(icon: .users, title: "Reviewers") {
                Text(pr.requestedReviewers.isEmpty ? "No reviewers requested" : pr.requestedReviewers.joined(separator: ", "))
            }
            summaryDetailRow(icon: .chats, title: "Comments") {
                Text(pr.comments == 0 ? "No comments" : "\(pr.comments) comment\(pr.comments == 1 ? "" : "s")")
            }
            summaryDetailRow(icon: .checkCircle, title: "Checks", color: checksColor(for: pr)) {
                Text(checksLabel(for: pr))
                    .foregroundStyle(checksColor(for: pr))
            }
            summaryDetailRow(icon: .gitPullRequest, title: "Status") {
                statusPicker(pr)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))

        summarySectionHeader("Description", isExpanded: $descriptionExpanded).padding(.top, 20)
        if descriptionExpanded {
            if pr.body.isEmpty {
                Text("No description provided.").font(.system(size: 13)).foregroundStyle(Color.dockMetadataText).padding(.top, 12)
            } else {
                MarkdownMessageView(markdown: pr.body).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
        }

        summarySectionHeader("Checks", count: pr.checks.isEmpty ? nil : pr.checks.count, isExpanded: $checksExpanded)
            .padding(.top, 20)
        if checksExpanded { checksSection(pr).padding(.top, 12) }

        let activityCount = (center.commitsByID[pr.id] ?? []).count + (center.commentsByID[pr.id] ?? []).count + 1
        summarySectionHeader("Activity", count: activityCount, isExpanded: $activityExpanded)
            .padding(.top, 20)
        if activityExpanded {
            activitySection(pr).padding(.top, 12)
            commentComposer(pr).padding(.top, 18).padding(.bottom, 40)
        }
    }.frame(maxWidth: 720, alignment: .leading) }

    private func summarySectionHeader(_ title: String, count: Int? = nil, isExpanded: Binding<Bool>) -> some View {
        Button { isExpanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                DockIcon(isExpanded.wrappedValue ? .caretDown : .caretRight, size: 13, color: Color.dockMetadataText)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockMetadataText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.dockSurface4))
                }
                Spacer()
            }
            .foregroundStyle(Color.dockPrimaryText)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        .accessibilityLabel("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title)")
    }

    @ViewBuilder
    private func checksSection(_ pr: PullRequestRecord) -> some View {
        if pr.checks.isEmpty {
            HStack(spacing: 12) {
            Text("No checks reported by GitHub.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button {
                    Task { await center.refreshSelectedDetail() }
                } label: {
                    DockIcon(.arrowsClockwise, size: 15, color: Color.dockSecondaryText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(center.isLoadingDetail)
                .help("Refresh checks")
                .accessibilityLabel("Refresh checks")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
        } else {
            VStack(spacing: 0) {
                ForEach(pr.checks) { check in
                    HStack(spacing: 13) {
                        DockIcon(checkIcon(for: check), size: 14, color: checkColor(for: check))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(checkColor(for: check).opacity(0.12)))
                        if let url = check.detailsURL { Link(check.name, destination: url) } else { Text(check.name) }
                        Spacer()
                        Text(checkPresentation(for: check))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    if check.id != pr.checks.last?.id { Divider().padding(.leading, 47) }
                }
            }
            .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
            .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
        }
    }

    private func activitySection(_ pr: PullRequestRecord) -> some View {
        let commits = center.commitsByID[pr.id] ?? []
        let comments = center.commentsByID[pr.id] ?? []
        return VStack(spacing: 7) {
            ForEach(commits) { commit in
                activityRow(icon: .gitBranch, iconColor: Color.dockMetadataText, title: commit.message, trailing: String(commit.id.prefix(7)), avatarURL: commit.authorAvatarURL, age: commit.committedAt.map(pullRequestAge))
            }
            ForEach(comments) { comment in
                activityRow(icon: .chats, iconColor: Color.dockAccent, title: "\(comment.author) commented", detail: comment.body, avatarURL: comment.authorAvatarURL, age: comment.createdAt.map(pullRequestAge))
            }
            activityRow(icon: .gitPullRequest, iconColor: Color.dockSuccess, title: "\(pr.author) opened this pull request", age: pr.updatedAt.map(pullRequestAge))
        }
    }

    private func activityRow(icon: Ph, iconColor: Color, title: String, detail: String? = nil, trailing: String? = nil, avatarURL: URL? = nil, age: String? = nil) -> some View {
        HStack(spacing: 10) {
            DockIcon(icon, size: 14, color: iconColor)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.dockSurface4.opacity(0.55)))
            VStack(alignment: .leading, spacing: detail == nil ? 0 : 5) {
                Text(title).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(2) }
            }
            Spacer(minLength: 12)
            if let trailing { Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dockMetadataText) }
            if let avatarURL { AsyncImage(url: avatarURL) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { avatarFallback } }.frame(width: 24, height: 24).clipShape(Circle()) }
            if let age { Text(age).foregroundStyle(Color.dockMetadataText) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }

    private func commentComposer(_ pr: PullRequestRecord) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $commentDraft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 104)
                .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
                .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
            if commentDraft.isEmpty {
                Text("Leave a comment")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
            HStack {
                avatarFallback
                Spacer()
                Button {
                    let draft = commentDraft
                    mutationCoordinator.requestComment(draft, for: pr)
                } label: {
                    if center.isPostingComment { ProgressView().controlSize(.small).frame(width: 34, height: 34) }
                    else { DockIcon(.arrowUp, size: 17, color: commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.dockMetadataText : Color.dockPrimaryText).frame(width: 34, height: 34).background(Circle().fill(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.dockSurface4 : Color.dockAccent)) }
                }
                .buttonStyle(.plain)
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || center.isPostingComment)
                .help("Add comment")
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func checkIcon(for check: GitHubCheckSummary) -> Ph { checkColor(for: check) == Color.dockSuccess ? .check : (checkColor(for: check) == Color.dockDestructive ? .x : .clock) }
    private func checkColor(for check: GitHubCheckSummary) -> Color {
        let conclusion = check.conclusion?.lowercased()
        if ["success", "neutral", "skipped"].contains(conclusion) { return Color.dockSuccess }
        if ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion) { return Color.dockDestructive }
        return Color.dockWarning
    }
    private func checkPresentation(for check: GitHubCheckSummary) -> String {
        guard check.status.lowercased() == "completed" else { return "Running" }
        switch check.conclusion?.lowercased() {
        case "success": return "Passed"
        case "failure": return "Failed"
        case "cancelled": return "Cancelled"
        case "skipped", "neutral": return "Skipped"
        default: return "Completed"
        }
    }

    @ViewBuilder
    private func authorAvatar(_ pr: PullRequestRecord) -> some View {
        if let url = pr.authorAvatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { avatarFallback }
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }
    private var avatarFallback: some View {
        DockIcon(.user, size: 15, color: Color.dockMetadataText)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.dockSurface2))
    }
    private func summaryDetailRow<Content: View>(icon: Ph, title: String, color: Color = Color.dockMetadataText, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 13) {
            DockIcon(icon, size: 14, color: color).frame(width: 18)
            Text(title).foregroundStyle(Color.dockMetadataText).frame(width: 84, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func statusPicker(_ pr: PullRequestRecord) -> some View {
        let current: PullRequestStatus = pr.isDraft ? .draft : .readyForReview
        return Menu {
            ForEach(PullRequestStatus.allCases) { status in
                Button {
                    mutationCoordinator.requestStatus(status, for: pr)
                } label: {
                    HStack {
                        Text(status.rawValue)
                        Spacer()
                        if status == current { Ph.check.image(size: 14) }
                    }
                }
                .disabled(status == .draft && !pr.isDraft)
            }
        } label: {
            HStack(spacing: 7) {
                if center.isUpdatingStatus { ProgressView().controlSize(.mini) }
                Text(current.rawValue)
                DockIcon(.caretDown, size: 15, color: Color.dockSecondaryText)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.dockSurface2))
        }
        .menuStyle(.borderlessButton)
        .disabled(center.isUpdatingStatus)
        .help("Change pull request status")
        .accessibilityLabel("Pull request status: \(current.rawValue)")
    }
    private func checksLabel(for pr: PullRequestRecord) -> String {
        if pr.checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return "Failed" }
        if pr.checks.contains(where: { $0.status.lowercased() != "completed" }) { return "In progress" }
        return pr.checks.isEmpty ? "No checks" : "Successful"
    }
    private func checksColor(for pr: PullRequestRecord) -> Color {
        if pr.checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return Color.dockDestructive }
        if pr.checks.contains(where: { $0.status.lowercased() != "completed" }) { return Color.dockWarning }
        return pr.checks.isEmpty ? Color.dockMetadataText : Color.dockSuccess
    }
    private func pullRequestAge(_ updatedAt: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(updatedAt))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }
    private func detailTabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.dockEase(duration: 0.18)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.dockPrimaryText : Color.dockMetadataText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).fill(selected ? Color.dockSurface4 : Color.clear))
        }
        .buttonStyle(.plain)
    }
    private func code(_ pr: PullRequestRecord) -> some View {
        let projection = PullRequestFilesProjection.state(
            files: center.filesByID[pr.id],
            isLoading: center.isLoadingDetail(for: pr.id),
            expectedFileCount: pr.changedFiles
        )
        return VStack(alignment: .leading, spacing: 10) {
            switch projection {
            case .loading:
                ProgressView("Loading changed files…").foregroundStyle(Color.dockMetadataText)
            case .unavailable:
                codeState(
                    title: "Changed files unavailable",
                    detail: "GitHub did not return the expected file data.",
                    actionTitle: "Retry"
                )
            case .empty:
                codeState(
                    title: "No changed files",
                    detail: "GitHub reports that this pull request currently has no changed files.",
                    actionTitle: "Refresh"
                )
            case .loaded(let files):
                HStack(alignment: .top, spacing: 14) {
                    if reviewPreferences.showsFileTree { fileTree(files) }
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(files) { file in
                                    fileSection(file)
                                        .id(file.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: selectedFileID) { _, id in
                            if let id { withAnimation(.dockEase(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                        }
                    }
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func codeState(title: String, detail: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(DockTypography.body)
                .foregroundStyle(Color.dockSecondaryText)
            Button(actionTitle) {
                Task { await center.refreshSelectedDetail() }
            }
            .buttonStyle(.dockSecondary)
            .controlSize(.small)
            .disabled(center.isLoadingDetail(for: center.selectedID ?? ""))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
    }

    private func codeToolbar(fileIDs: Set<String>) -> some View {
        HStack(spacing: 4) {
            Menu {
                Toggle("Enable word wrap", isOn: $reviewPreferences.wordWrap)
                Toggle("Enable rich preview", isOn: $reviewPreferences.richPreview)
                Toggle("Enable word diffs", isOn: $reviewPreferences.wordDiffs)
            } label: {
                PullRequestReviewToolbarIcon(name: .sliders, accessibilityLabel: "Review options", tooltip: "Review options")
            }
            // `.borderlessButton` drops custom-shape labels on macOS, leaving only the indicator.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Review options")

            Button {
                reviewPreferences.setAllExpanded(fileIDs)
            } label: {
                PullRequestReviewToolbarIcon(
                    name: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? .arrowsInLineVertical : .caretUpDown,
                    accessibilityLabel: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs",
                    tooltip: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs"
                )
            }
            .buttonStyle(.plain)
            .help(reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs")

            Button {
                reviewPreferences.diffMode = reviewPreferences.diffMode == .unified ? .split : .unified
            } label: {
                PullRequestReviewToolbarIcon(
                    name: reviewPreferences.diffMode == .unified ? .columns : .rows,
                    accessibilityLabel: "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff",
                    tooltip: "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff"
                )
            }
            .buttonStyle(.plain)
            .help("Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff")

            Button {
                reviewPreferences.showsFileTree.toggle()
            } label: {
                PullRequestReviewToolbarIcon(
                    name: .sidebar,
                    accessibilityLabel: reviewPreferences.showsFileTree ? "Hide file tree" : "Show file tree",
                    isSelected: reviewPreferences.showsFileTree,
                    tooltip: reviewPreferences.showsFileTree ? "Hide file tree" : "Show file tree"
                )
            }
            .buttonStyle(.plain)
            .help(reviewPreferences.showsFileTree ? "Hide file tree" : "Show file tree")
        }
        .frame(height: 34)
    }

    private func fileTree(_ files: [PullRequestFile]) -> some View {
        let filesByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Changed files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("\(files.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.dockSurface4))
                Spacer(minLength: 4)
                PullRequestDiffStat(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(PullRequestFileTreeBuilder.make(files: files)) { node in
                        let appearance = fileTreeAppearance(for: node)
                        PullRequestFileTreeRow(
                            node: node,
                            icon: appearance.icon,
                            iconColor: appearance.color,
                            file: node.fileID.flatMap { filesByID[$0] },
                            // Folders have no fileID; comparing optionals would highlight them all when nothing is selected.
                            isSelected: node.fileID != nil && selectedFileID == node.fileID
                        ) {
                            guard let fileID = node.fileID else { return }
                            selectedFileID = fileID
                            if !reviewPreferences.expandedFileIDs.contains(fileID) { reviewPreferences.toggleExpanded(fileID) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 240, alignment: .leading)
        .overlay(alignment: .trailing) { Color.dockBorderLight.frame(width: 0.5) }
    }

    private func fileTreeAppearance(for node: PullRequestFileTreeNode) -> (icon: Ph, color: Color) {
        guard !node.isDirectory, let path = node.fileID else { return (.folder, Color.dockSecondaryText) }
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return (.bracketsCurly, Color.dockWarning)
        case "js", "jsx", "ts", "tsx", "vue", "svelte": return (.bracketsCurly, Color.dockAccent)
        case "json", "yaml", "yml", "toml", "xml": return (.bracketsCurly, Color.dockSuccess)
        case "md", "markdown", "mdx": return (.fileText, Color.dockAccent)
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico": return (.image, Color.dockWarning)
        case "sh", "zsh", "bash", "fish": return (.terminal, Color.dockSuccess)
        case "css", "scss", "sass", "html": return (.fileText, Color.dockDestructive)
        default:
            return (name.hasPrefix(".env") ? .gear : .fileText, name.hasPrefix(".env") ? Color.dockWarning : Color.dockMetadataText)
        }
    }

    private func fileSection(_ file: PullRequestFile) -> some View {
        let expanded = reviewPreferences.expandedFileIDs.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedFileID = file.id
                reviewPreferences.toggleExpanded(file.id)
            } label: {
                HStack(spacing: 8) {
                    DockIcon(expanded ? .caretDown : .caretRight, size: 13, color: Color.dockMetadataText)
                    DockIcon(.fileText, size: 15, color: Color.dockSecondaryText)
                    Text(file.path).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                    Text(file.status.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer()
                    HStack(spacing: 8) {
                        Text("+\(file.additions)").foregroundStyle(Color.dockSuccess)
                        Text("−\(file.deletions)").foregroundStyle(Color.dockDestructive)
                    }.font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { fileContent(file) }
        }
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }

    @ViewBuilder
    private func fileContent(_ file: PullRequestFile) -> some View {
        if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), let patch = file.patch, isMarkdown(file.path) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RICH PREVIEW").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Color.dockMetadataText)
                MarkdownMessageView(markdown: previewMarkdown(from: patch)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.dockSurface2)
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.borderless).font(.system(size: 10, weight: .semibold))
            }.padding(8)
        } else if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), isImage(file.path), let url = file.webURL {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: imagePreviewURL(for: url)) { phase in
                    if let image = phase.image { image.resizable().scaledToFit().frame(maxHeight: 420) }
                    else { Text("Image preview unavailable. Open on GitHub to view this file.").foregroundStyle(Color.dockMetadataText) }
                }
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.borderless).font(.system(size: 10, weight: .semibold))
            }.padding(8)
        } else if let patch = file.patch {
            diffPatch(patch)
        } else {
            HStack { Text("Binary or truncated patch").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText); Spacer(); if let url = file.webURL { Link("OPEN ON GITHUB", destination: url).font(.system(size: 10, weight: .bold)) } }.padding(12)
        }
    }

    private func isMarkdown(_ path: String) -> Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }
    private func isImage(_ path: String) -> Bool { ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains((path as NSString).pathExtension.lowercased()) }
    private func imagePreviewURL(for url: URL) -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count > 4, components[2] == "blob" else { return url }
        let rawPath = Array(components[0...1]) + Array(components.dropFirst(3))
        return URL(string: "https://raw.githubusercontent.com/\(rawPath.joined(separator: "/"))") ?? url
    }
    private func previewMarkdown(from patch: String) -> String { PullRequestDiffPresentation.lines(patch).filter { $0.kind != .deletion && $0.kind != .hunk && $0.kind != .metadata }.map { $0.kind == .addition ? String($0.text.dropFirst()) : $0.text }.joined(separator: "\n") }

    @ViewBuilder
    private func diffPatch(_ patch: String) -> some View {
        let rows = diffPresentationCache.rows(for: patch)
        Group {
            if reviewPreferences.diffMode == .split {
                // Split reviews must always start with both sides visible. Each
                // pane shares the available viewport instead of sizing itself to
                // the longest line in the patch.
                diffRows(rows)
            } else if reviewPreferences.wordWrap {
                diffRows(rows)
            } else {
                ScrollView(.horizontal, showsIndicators: true) { diffRows(rows).fixedSize(horizontal: true, vertical: false) }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous))
    }

    @ViewBuilder
    private func diffRows(_ rows: [PullRequestDiffSplitRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if reviewPreferences.diffMode == .split {
                    HStack(spacing: 0) {
                        splitDiffColumn(row.left, counterpart: row.right?.text)
                        Color.dockBorderLight.frame(width: 0.5)
                        splitDiffColumn(row.right, counterpart: row.left?.text)
                    }
                } else if let left = row.left, let right = row.right, left.kind == .deletion, right.kind == .addition {
                    diffLineView(left, counterpart: right.text)
                    diffLineView(right, counterpart: left.text)
                } else {
                    diffLineView(row.left ?? row.right, counterpart: nil)
                }
            }
        }
    }

    private func splitDiffColumn(_ line: PullRequestDiffLine?, counterpart: String?) -> some View {
        diffLineView(line, counterpart: counterpart)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
    }

    @ViewBuilder
    private func diffLineView(_ line: PullRequestDiffLine?, counterpart: String?) -> some View {
        if let line {
            PullRequestDiffLineView(
                line: line,
                counterpart: counterpart,
                wordDiffsEnabled: reviewPreferences.wordDiffs && (line.kind == .addition || line.kind == .deletion)
            )
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 19)
        }
    }
}

enum RepositoryReviewWorkspaceMode: Equatable {
    case pullRequests
    case issues

    var isIssues: Bool { self == .issues }
    var title: String { isIssues ? "Issues" : "Pull requests" }
    var subtitle: String {
        isIssues ? "GitHub issues across your repositories" : "Review open changes across your repositories"
    }
    var icon: Ph { isIssues ? .fileText : .gitPullRequest }
}

struct PullRequestWorkspace: View {
    @ObservedObject var center: PullRequestCenterModel
    let projects: [ProjectSummary]
    let onOpenChat: (PullRequestRecord) -> Void
    var onOpenIssueChat: (GitHubIssueRecord) -> Void = { _ in }
    let mode: RepositoryReviewWorkspaceMode
    @StateObject private var issueCenter = IssueCenterModel()

    init(
        center: PullRequestCenterModel,
        projects: [ProjectSummary],
        onOpenChat: @escaping (PullRequestRecord) -> Void,
        onOpenIssueChat: @escaping (GitHubIssueRecord) -> Void = { _ in },
        mode: RepositoryReviewWorkspaceMode = .pullRequests
    ) {
        self.center = center
        self.projects = projects
        self.onOpenChat = onOpenChat
        self.onOpenIssueChat = onOpenIssueChat
        self.mode = mode
    }

    var body: some View {
        VStack(spacing: 0) {
            DockPageHeader(
                title: mode.title,
                subtitle: mode.subtitle,
                onRefresh: { Task { await refreshActiveWorkspace() } },
                isRefreshing: mode.isIssues ? issueCenter.isRefreshing : center.isRefreshing
            )
            if mode.isIssues {
                IssueWorkspace(center: issueCenter, projects: projects, onOpenChat: onOpenIssueChat)
            } else {
                HSplitView {
                    listPane.frame(minWidth: 300, idealWidth: 390, maxWidth: 460, maxHeight: .infinity)
                    PullRequestDetailView(center: center, onOpenChat: onOpenChat)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dockCanvas)
        .task {
            if mode == .pullRequests, center.records.isEmpty { await center.refresh(projects: projects) }
        }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
    }

    private func refreshActiveWorkspace() async {
        if mode.isIssues {
            await issueCenter.refresh(projects: projects)
        } else {
            await center.refresh(projects: projects)
        }
    }

    private var listPane: some View { VStack(spacing: 0) {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 15, color: Color.dockMetadataText)
                TextField("Search pull requests", text: $center.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.dockControlSurface)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))

            HStack(spacing: 4) {
                ForEach(PullRequestFilter.allCases) { filter in
                    DockTabButton(title: filter.rawValue, isSelected: center.filter == filter) {
                        center.filter = filter
                    }
                }
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        if let error = center.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(Color.dockWarning).padding(.horizontal, 18).padding(.bottom, 8) }
        ScrollView {
            LazyVStack(spacing: 2) {
                if center.isInitialLoad {
                    ForEach(0..<6, id: \.self) { index in listLoadingRow(index: index) }
                } else {
                    ForEach(center.visible) { pr in
                        Button { center.selectedID = pr.id } label: { PullRequestRowView(pullRequest: pr, isSelected: center.selectedID == pr.id) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }.background(Color.dockSurface2.opacity(0.55)) }

    private func listLoadingRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                RepositoryShimmerBlock(width: 18, height: 18, cornerRadius: 5)
                RepositoryShimmerBlock(width: index.isMultiple(of: 2) ? 184 : 228, height: 12, cornerRadius: 4)
            }
            RepositoryShimmerBlock(width: index.isMultiple(of: 3) ? 122 : 160, height: 9, cornerRadius: 3)
            RepositoryShimmerBlock(width: 48, height: 8, cornerRadius: 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous).fill(Color.dockSurface2))
        .accessibilityHidden(true)
    }
}
