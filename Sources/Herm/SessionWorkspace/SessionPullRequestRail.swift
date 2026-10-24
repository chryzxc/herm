import Foundation
import SwiftUI

/// References are projected from loaded Hermes history, never a repository-wide PR list.
enum SessionPullRequestReferences {
    static func extract(texts: [String], defaults: UserDefaults = .standard) -> [GitHubItemReference] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var seen = Set<String>()
        return texts.flatMap { text in
            let normalized = text.replacingOccurrences(of: "\\/", with: "/")
            return (detector?.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) ?? [])
                .compactMap { match -> GitHubItemReference? in
                    guard let url = match.url,
                        let reference = GitHubMarkdownLink.reference(for: url, defaults: defaults),
                        reference.kind == .pullRequest,
                        seen.insert(reference.id.lowercased()).inserted
                    else { return nil }
                    return reference
                }
        }
    }

    static func texts(messages: [ChatMessage], activity: [ActiveToolCall]) -> [String] {
        messages.flatMap { [$0.text] + $0.activity.compactMap(\.result) } + activity.compactMap(\.result)
    }
}

@MainActor
final class SessionPullRequestRailModel: ObservableObject {
    @Published private(set) var references: [GitHubItemReference] = []
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    let details: PullRequestDetailStore
    private let api: PullRequestCenterAPI
    private var refreshGeneration = UUID()

    init(api: PullRequestCenterAPI = .init(), details: PullRequestDetailStore = .shared) {
        self.api = api
        self.details = details
    }

    func discover(messages: [ChatMessage], activity: [ActiveToolCall]) {
        let found = SessionPullRequestReferences.extract(
            texts: SessionPullRequestReferences.texts(messages: messages, activity: activity))
        if references != found { references = found }
    }

    func discoverActivity(_ activity: [ActiveToolCall]) {
        let found = SessionPullRequestReferences.extract(texts: activity.compactMap(\.result))
        let existing = Set(references.map { $0.id.lowercased() })
        let added = found.filter { !existing.contains($0.id.lowercased()) }
        if !added.isEmpty { references += added }
    }

    func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        isRefreshing = true
        defer { if refreshGeneration == generation { isRefreshing = false } }
        for reference in references {
            guard !Task.isCancelled else { return }
            do {
                let summary = try await api.resolve(
                    reference, localPath: details.records[reference.id]?.localPath ?? "")
                guard let record = await api.detail(summary) else { throw GitHubRequestError.unavailable }
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                details.records[record.id] = record.retainingMergedState(from: details.records[record.id])
                failures[reference.id] = nil
            } catch {
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                failures[reference.id] = HermesDiagnosticsService.safeSummary(error.localizedDescription)
            }
        }
    }
}

struct SessionRailChangeSummary: Equatable {
    let repositoryName: String
    let fileCount: Int
    let untrackedCount: Int
    var files: [RepositoryFileChange] = []

    static func make(path: String?, repository: RepositorySnapshot, changes: RepositoryChangeSnapshot?) -> Self? {
        guard let path, repository.isGitRepository, !repository.isStale,
            RepositorySnapshot.stableID(path: repository.path) == RepositorySnapshot.stableID(path: path),
            let changes, changes.repositoryID == RepositorySnapshot.stableID(path: path), !changes.files.isEmpty
        else { return nil }
        return Self(
            repositoryName: URL(fileURLWithPath: path).lastPathComponent,
            fileCount: Set(changes.files.map(\.path)).count,
            untrackedCount: changes.untrackedCount, files: changes.files)
    }
}

struct SessionPullRequestRail: View {
    @ObservedObject var model: DockModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    let repositoryPath: String?
    let onViewAllChanges: () -> Void
    let onViewPullRequest: (GitHubItemReference) async -> Bool
    let onRefreshChanges: () async -> Void
    @StateObject private var rail = SessionPullRequestRailModel()
    @ObservedObject private var details = PullRequestDetailStore.shared
    @State private var refreshID = UUID()
    @State private var lineSummary: RepositoryChangeLineSummary?
    @State private var lineSnapshot: RepositoryChangeSnapshot?

    private var changes: SessionRailChangeSummary? {
        .make(path: repositoryPath, repository: workflow.repository, changes: workflow.changes)
    }

    var body: some View {
        ScrollView {
            SessionRailCard(
                repositoryName: repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                repositoryPath: repositoryPath, changesRevision: workflow.changes?.refreshedAt,
                changes: changes, lines: lineSnapshot == workflow.changes ? lineSummary : nil,
                changesUnavailable: repositoryPath == workflow.repository.path && workflow.repository.isStale,
                references: rail.references, records: details.records, failures: rail.failures,
                isRefreshing: rail.isRefreshing || workflow.isRefreshing,
                onRefresh: { refreshID = UUID() },
                onViewAllChanges: onViewAllChanges, onViewPullRequest: onViewPullRequest
            )
            .padding(16)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .onChange(of: model.messagesRevision, initial: true) { _, _ in
            rail.discover(messages: model.messages, activity: model.streamingTurnActivity)
        }
        .onChange(of: model.activityPresentationRevision) { _, _ in
            rail.discoverActivity(model.streamingTurnActivity)
        }
        .task(id: rail.references.map(\.id) + [refreshID.uuidString]) { await rail.refresh() }
        .task(id: [repositoryPath ?? "", refreshID.uuidString]) { await onRefreshChanges() }
        .task(id: workflow.changes) {
            guard changes != nil, let repositoryPath, let snapshot = workflow.changes else { return }
            let lines = await RepositoryService.changeLineSummary(path: repositoryPath, changes: snapshot)
            guard !Task.isCancelled else { return }
            lineSummary = lines
            lineSnapshot = snapshot
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session rail")
    }
}

struct SessionRailCard: View {
    let repositoryName: String?
    var repositoryPath: String? = nil
    var changesRevision: Date? = nil
    let changes: SessionRailChangeSummary?
    let lines: RepositoryChangeLineSummary?
    var changesUnavailable = false
    let references: [GitHubItemReference]
    let records: [String: PullRequestRecord]
    let failures: [String: String]
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onViewAllChanges: () -> Void
    let onViewPullRequest: (GitHubItemReference) async -> Bool
    @State private var expandedChanges = false
    @State private var expandedPullRequests: Set<String> = []
    @State private var openingPullRequestID: String?
    @State private var failedPullRequestID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(repositoryName ?? "Session context")
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if isRefreshing {
                    ProgressView().controlSize(.mini).frame(width: 24, height: 24)
                } else {
                    DockMenu {
                        Button("Refresh session rail", icon: .arrowsClockwise, action: onRefresh)
                    } label: {
                        DockIcon(.dotsThree, size: 14, color: .dockSecondaryText)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .help("Session rail actions").accessibilityLabel("Session rail actions")
                }
            }
            if let changes {
                DisclosureGroup(isExpanded: $expandedChanges) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let repositoryPath {
                            ForEach(changes.files) { file in
                                SessionRailFileQuickView(
                                    path: repositoryPath, file: file, revision: changesRevision)
                            }
                        }
                        Button("View all changes", action: onViewAllChanges)
                            .buttonStyle(.dockLink).padding(.top, 4)
                    }
                    .padding(.top, 8)
                } label: {
                    changesRow(changes)
                }
                .disclosureGroupStyle(DockDisclosureGroupStyle())
                .accessibilityIdentifier("session-rail.changes")
            } else if changesUnavailable {
                Text("Changes unavailable. Refresh to retry.")
                    .dockFont(.body).foregroundStyle(Color.dockWarning)
            }
            if !references.isEmpty {
                if changes != nil || changesUnavailable {
                    Color.dockBorderLight.frame(height: DockLayout.hairline)
                }
                HStack(spacing: 6) {
                    Text("Pull requests").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 0)
                    Text(references.count.formatted()).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
                ForEach(references) { reference in
                    entry(reference)
                }
            } else if changes == nil && !changesUnavailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRefreshing ? "Loading session context…" : "Nothing here yet")
                        .dockFont(.body, weight: .semibold)
                    Text("Session details will appear here.")
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 16, isQuiet: true)
    }

    private func changesRow(_ changes: SessionRailChangeSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                changesLabel
                Spacer(minLength: 4)
                changeCounts(changes)
            }
            VStack(alignment: .leading, spacing: 6) {
                changesLabel
                changeCounts(changes).padding(.leading, 23)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Show local changes in \(changes.repositoryName)")
        .accessibilityLabel("Changes, \(changes.fileCount) changed files in \(changes.repositoryName)")
    }

    private var changesLabel: some View {
        HStack(spacing: 8) {
            DockIcon(.gitDiff, size: 15, color: .dockSecondaryText)
            Text("Changes").dockFont(.body).foregroundStyle(Color.dockPrimaryText)
        }
    }

    private func changeCounts(_ changes: SessionRailChangeSummary) -> some View {
        HStack(spacing: 5) {
            if let lines, changes.untrackedCount < changes.fileCount,
                lines.binaryFiles == 0 || lines.additions > 0 || lines.deletions > 0
            {
                Text("+\(lines.additions.formatted())").foregroundStyle(Color.dockSuccess)
                Text("−\(lines.deletions.formatted())").foregroundStyle(Color.dockDestructive)
            } else {
                Text("\(changes.fileCount) \(changes.fileCount == 1 ? "file" : "files")")
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .dockFont(.body).monospacedDigit().fixedSize()
        .help("Tracked text changes against HEAD; \(changes.untrackedCount) new files. Binary lines are not counted.")
    }

    private func entry(_ reference: GitHubItemReference) -> some View {
        let record = records[reference.id]
        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedPullRequests.contains(reference.id) },
                set: { expanded in
                    if expanded {
                        expandedPullRequests.insert(reference.id)
                    } else {
                        expandedPullRequests.remove(reference.id)
                    }
                })
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let record {
                    Text(record.repository.id).foregroundStyle(Color.dockMetadataText)
                    Text("\(record.headBranch) → \(record.baseBranch)")
                        .foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
                    Text("By \(record.author)").foregroundStyle(Color.dockSecondaryText)
                    if let additions = record.additions, let deletions = record.deletions {
                        HStack(spacing: 6) {
                            Text("+\(additions.formatted())").foregroundStyle(Color.dockSuccess)
                            Text("−\(deletions.formatted())").foregroundStyle(Color.dockDestructive)
                        }.monospacedDigit()
                    }
                    if let warning = record.detailWarning {
                        Text(warning).foregroundStyle(Color.dockWarning)
                    }
                }
                if let failure = failures[reference.id] {
                    Text(record == nil ? "Details unavailable. \(failure)" : "Last fetched details. \(failure)")
                        .foregroundStyle(Color.dockWarning)
                } else if record == nil {
                    Text("Loading details…").foregroundStyle(Color.dockSecondaryText)
                }
                Button(openingPullRequestID == reference.id ? "Opening…" : "View in GitHub panel") {
                    openingPullRequestID = reference.id
                    failedPullRequestID = nil
                    Task {
                        let opened = await onViewPullRequest(reference)
                        openingPullRequestID = nil
                        if !opened { failedPullRequestID = reference.id }
                    }
                }
                .buttonStyle(.dockLink).disabled(openingPullRequestID != nil)
                if failedPullRequestID == reference.id {
                    Text("Could not open pull request. Refresh and try again.").foregroundStyle(Color.dockWarning)
                }
            }
            .dockFont(.body).padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    DockIcon(
                        record?.presentationIcon ?? .gitPullRequest, size: 15,
                        color: record?.presentationColor ?? .dockSecondaryText)
                    Text(record?.title ?? "Pull request #\(reference.number)")
                        .dockFont(.body).multilineTextAlignment(.leading).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text("#\(String(reference.number))").foregroundStyle(Color.dockMetadataText)
                    if let record {
                        Text(record.readinessLabel).foregroundStyle(record.readinessColor)
                    }
                }
                .dockFont(.metadata).padding(.leading, 23)
            }
        }
        .disclosureGroupStyle(DockDisclosureGroupStyle())
        .accessibilityIdentifier("session-rail.pr.\(reference.number)")
    }
}

private struct SessionRailFileQuickView: View {
    let path: String
    let file: RepositoryFileChange
    let revision: Date?
    @State private var document: DiffDocument?
    @State private var isLoading = true
    @State private var isExpanded = false
    @State private var isTruncated = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if isLoading {
                    Text("Loading diff…").foregroundStyle(Color.dockSecondaryText)
                } else if let document {
                    if let notice = document.fileNotice {
                        Text(notice).foregroundStyle(Color.dockSecondaryText)
                    }
                    if document.lines.isEmpty {
                        Text("No text changes to preview.").foregroundStyle(Color.dockSecondaryText)
                    } else {
                        NativeDiffCanvas(
                            document: document, split: false, wraps: true, wordDiffs: true,
                            findRequest: 0, onNote: nil, onComment: nil
                        )
                        .frame(height: min(240, max(100, CGFloat(document.lines.count) * 20)))
                    }
                    if isTruncated {
                        Text("Partial preview. View all changes for the full review.")
                            .foregroundStyle(Color.dockMetadataText)
                    }
                } else {
                    Text("Diff unavailable. Collapse and reopen to retry.").foregroundStyle(Color.dockWarning)
                }
            }
            .dockFont(.body).padding(.top, 6)
            .task(id: revision) {
                isLoading = true
                let diff = await RepositoryService.diff(path: path, file: file)
                guard !Task.isCancelled else { return }
                document = diff.map { DiffDocument(path: file.path, patch: $0.text) }
                isTruncated = diff?.isTruncated == true
                isLoading = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.path).dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2).truncationMode(.middle)
                Text("\(file.isStaged ? "Staged" : "Working tree") · \(file.status.rawValue.capitalized)")
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            }
        }
        .disclosureGroupStyle(DockDisclosureGroupStyle())
    }
}
