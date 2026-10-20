import Foundation
import SwiftUI

enum PullRequestFilter: String, CaseIterable, Identifiable {
    case all = "All", reviewing = "Reviewing", authored = "Authored", merged = "Recently merged"
    var id: Self { self }
}

struct PullRequestFilterPicker: View {
    @Binding var selection: PullRequestFilter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            DockTabBar(options: PullRequestFilter.allCases, selection: $selection, title: { $0.rawValue })
                .fixedSize(horizontal: true, vertical: false)
            DockMenuPicker(title: selection.rawValue, selection: $selection) {
                ForEach(PullRequestFilter.allCases) { filter in
                    DockMenuOption(filter.rawValue, value: filter)
                }
            }
            .font(DockTypography.control)
            .frame(height: 30)
            .accessibilityLabel("Pull request filter")
            .accessibilityValue(selection.rawValue)
        }
    }
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

struct PullRequestFile: Identifiable, Equatable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?
    let webURL: URL?
    var previousPath: String? = nil
    var id: String { path }
}

enum PullRequestFilesProjection: Equatable {
    case loading
    case unavailable
    case empty
    case loaded([PullRequestFile])

    static func state(files: [PullRequestFile]?, isLoading: Bool, expectedFileCount: Int?) -> Self {
        if isLoading { return .loading }
        guard let files else { return .unavailable }
        guard files.isEmpty else { return .loaded(files) }
        // An empty `/files` response is authoritative only when the PR detail
        // agrees that there are no changed files. Otherwise expose the retry
        // action instead of presenting a failed response as a valid empty PR.
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

/// A GitHub issue-timeline event (draft/ready toggles, labels, reviews, merges…).
struct PullRequestEvent: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let actor: String
    let detail: String?
    let createdAt: Date?

    var actorAvatarURL: URL? = nil

    /// GitHub-style sentence plus icon; `nil` for events too noisy to show.
    var presentation: (text: String, icon: Ph)? {
        switch kind {
        case "ready_for_review": return ("\(actor) marked this pull request as ready for review", .checkCircle)
        case "convert_to_draft": return ("\(actor) marked this pull request as draft", .pencil)
        case "closed": return ("\(actor) closed this pull request", .xCircle)
        case "reopened": return ("\(actor) reopened this pull request", .arrowsClockwise)
        case "merged": return ("\(actor) merged this pull request", .gitMerge)
        case "labeled": return ("\(actor) added the \(detail ?? "") label", .tag)
        case "unlabeled": return ("\(actor) removed the \(detail ?? "") label", .tag)
        case "assigned": return ("\(actor) assigned \(detail ?? "someone")", .user)
        case "unassigned": return ("\(actor) unassigned \(detail ?? "someone")", .user)
        case "review_requested": return ("\(actor) requested a review from \(detail ?? "someone")", .eye)
        case "review_request_removed": return ("\(actor) removed the review request for \(detail ?? "someone")", .eye)
        case "renamed": return ("\(actor) changed the title to \(detail ?? "")", .pencil)
        case "head_ref_force_pushed": return ("\(actor) force-pushed the branch", .gitBranch)
        case "locked": return ("\(actor) locked this conversation", .lock)
        case "unlocked": return ("\(actor) unlocked this conversation", .lock)
        default: return nil
        }
    }
}

enum PullRequestStatus: String, CaseIterable, Identifiable, Sendable {
    case draft = "Draft"
    case readyForReview = "Ready for review"
    case closed = "Closed"
    case reopened = "Reopen"
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

typealias PullRequestDiffLineKind = DiffLineKind
typealias PullRequestDiffLine = DiffLine
typealias PullRequestDiffSplitRow = DiffSplitRow
typealias PullRequestDiffPresentation = DiffPresentation

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

struct PullRequestReviewToolbarIcon: View {
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
                .dockSelectionFill(isSelected, fallback: isSelected ? Color.dockSurface4 : (isHovered ? Color.dockSurface4.opacity(0.72) : Color.clear))
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

struct PullRequestRecord: Identifiable, Equatable, Sendable {
    let repository: GitHubRepositoryReference
    var localPath: String
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
    var mergedAt: Date? = nil
    var createdAt: Date? = nil
    var nodeID: String? = nil
    var state: String = "open"
    var headRevision: String? = nil
    var baseRevision: String? = nil
    var mergeability: GitHubMergeability = .unknown
    var mergeState: String? = nil
    var reviewDecision: String? = nil
    var viewerCanUpdate: Bool? = nil
    var checksAvailable = false
    var reviewsAvailable = false
    var refreshedAt: Date? = nil
    var labels: [String] = []
    var detailWarning: String? = nil
    var reference: GitHubItemReference { .init(repository: repository, number: number, kind: .pullRequest, nodeID: nodeID) }
    var id: String { "github:\(repository.id)#\(number)" }
    /// PR identifiers are not quantities: never localize them with grouping
    /// separators (for example, render `4878`, never `4,878`).
    var displayNumber: String { String(number) }

    var isOpenForWork: Bool { state == "open" && mergedAt == nil }
    var canAnalyzeConflicts: Bool {
        isOpenForWork && mergeability == .conflicting && headRevision != nil && baseRevision != nil
    }
    var availableStatusActions: [PullRequestStatus] {
        guard mergedAt == nil else { return [] }
        if state == "closed" { return [.reopened] }
        guard state == "open" else { return [] }
        return [isDraft ? .readyForReview : .draft, .closed]
    }
    var checksSummary: String {
        var parts: [String] = []
        for (count, label) in [(checks.filter { $0.conclusion == "success" }.count, "passed"),
                               (checks.filter(\.isFailure).count, "failed"),
                               (checks.filter(\.isPending).count, "pending"),
                               (checks.filter { ["skipped", "neutral"].contains($0.conclusion ?? "") }.count, "skipped")] where count > 0 {
            parts.append("\(count) \(label)")
        }
        let unknown = checks.filter { !$0.isSuccess && !$0.isFailure && !$0.isPending }.count
        if unknown > 0 { parts.append("\(unknown) unknown") }
        if !checksAvailable { parts.append("Check status incomplete") }
        return parts.isEmpty ? "No checks reported" : parts.joined(separator: " · ")
    }

    var readinessLabel: String {
        if mergedAt != nil { return "Merged" }
        if state == "closed" { return "Closed" }
        if mergeability == .conflicting { return "Conflicts" }
        if isDraft { return "Draft" }
        if checks.contains(where: \.isFailure) { return "Checks failed" }
        if reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
        if checks.contains(where: \.isPending) { return "Checks running" }
        guard checksAvailable else { return "Checks not loaded" }
        if reviewDecision == "REVIEW_REQUIRED" { return "Review required" }
        if !checks.isEmpty && !checks.allSatisfy(\.isSuccess) { return "Check status unknown" }
        return checks.isEmpty ? "No checks" : "Checks passed"
    }

}

struct PullRequestCenterFailure: Error { let repository: String }


extension PullRequestRecord {
    func activityItems(comments: [PullRequestComment], commits: [PullRequestCommit], events: [PullRequestEvent]) -> [GitHubConversationItem] {
        var items = comments.map { GitHubConversationItem(id: "comment:" + $0.id, author: $0.author, summary: "commented", body: $0.body, date: $0.createdAt, url: $0.webURL, avatarURL: $0.authorAvatarURL) }
        items += commits.map { GitHubConversationItem(id: "commit:" + $0.id, author: $0.author, summary: $0.message, body: "", date: $0.committedAt, url: $0.webURL, avatarURL: $0.authorAvatarURL) }
        items += reviews.map { GitHubConversationItem(id: "review:" + $0.id, author: $0.author, summary: $0.state.replacingOccurrences(of: "_", with: " ").capitalized, body: $0.body, date: $0.submittedAt, url: $0.webURL, avatarURL: $0.authorAvatarURL) }
        items += events.compactMap { event in event.presentation.map { GitHubConversationItem(id: "event:" + event.id, author: event.actor, summary: String($0.text.dropFirst((event.actor + " ").count)), body: "", date: event.createdAt, url: nil, avatarURL: event.actorAvatarURL) } }
        return items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

}
