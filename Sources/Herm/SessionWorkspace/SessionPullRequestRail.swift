import Combine
import Foundation
import SwiftUI

/// Explicit session links and targeted PR operations, never broad tool-result listings.
enum SessionPullRequestReferences {
    static func extract(texts: [String]) -> [GitHubItemReference] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return unique(extract(texts: texts, detector: detector))
    }

    private static func extract(texts: [String], detector: NSDataDetector?) -> [GitHubItemReference] {
        texts.flatMap { text in
            let normalized = text.replacingOccurrences(of: "\\/", with: "/")
            return (detector?.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) ?? [])
                .compactMap { match -> GitHubItemReference? in
                    guard let url = match.url,
                        let reference = GitHubMarkdownLink.reference(for: url),
                        reference.kind == .pullRequest
                    else { return nil }
                    return reference
                }
        }
    }

    static func unique(_ references: [GitHubItemReference]) -> [GitHubItemReference] {
        var seen = Set<String>()
        return references.filter { seen.insert($0.id.lowercased()).inserted }
    }

    private struct ToolInput: Equatable, Sendable {
        let input: String
        let arguments: [String: String]?
        let result: String?

        init(_ call: ActiveToolCall) {
            input = call.input
            arguments = call.args
            result = call.result
        }
    }

    private static func toolReferences(_ call: ToolInput, detector: NSDataDetector?) -> [GitHubItemReference] {
        let inputs = [call.input] + Array((call.arguments ?? [:]).values)
        // Broad listings and links in unrelated tool inputs do not establish ownership.
        guard
            inputs.contains(where: {
                $0.range(
                    of:
                        #"\bgh\s+pr\s+(?:view|create|diff|checks|checkout|edit|review|merge|close|reopen|ready|comment)\b"#,
                    options: .regularExpression) != nil
            })
        else { return [] }
        let targets = unique(extract(texts: inputs, detector: detector))
        guard let result = call.result else { return targets }
        let references = unique(extract(texts: [result], detector: detector))
        guard references.count == 1,
            targets.isEmpty || targets.contains(references[0])
                || inputs.contains(where: {
                    $0.range(of: #"\bgh\s+pr\s+create\b"#, options: .regularExpression) != nil
                })
        else { return targets }
        return targets + references
    }

    struct Message: Sendable {
        let id: UUID
        let text: String
        let activity: [ActiveToolCall]

        init(_ message: ChatMessage) {
            id = message.id
            text = message.text
            activity = message.activity
        }
    }

    struct Index: Sendable {
        private var messages: [UUID: (String, [GitHubItemReference])] = [:]
        private var tools: [String: (ToolInput, [GitHubItemReference])] = [:]
        private(set) var references: [GitHubItemReference] = []

        func scan(messages: [Message] = [], activity: [ActiveToolCall] = []) async -> Self? {
            guard !messages.isEmpty || !activity.isEmpty else { return Self() }
            let worker = Task.detached(priority: .utility) {
                self.scanning(messages: messages, activity: activity)
            }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }

        private func scanning(messages: [Message], activity: [ActiveToolCall]) -> Self? {
            var updated = Self()
            updated.messages.reserveCapacity(messages.count)
            var references: [GitHubItemReference] = []
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            for message in messages {
                guard !Task.isCancelled else { return nil }
                let found =
                    if let prior = self.messages[message.id], prior.0 == message.text { prior.1 } else {
                        extract(texts: [message.text], detector: detector)
                    }
                updated.messages[message.id] = (message.text, found)
                references += found
            }
            for calls in messages.map(\.activity) + [activity] {
                for call in calls {
                    guard !Task.isCancelled else { return nil }
                    let input = ToolInput(call)
                    let found =
                        if let prior = updated.tools[call.id] ?? tools[call.id], prior.0 == input { prior.1 } else {
                            toolReferences(input, detector: detector)
                        }
                    updated.tools[call.id] = (input, found)
                    references += found
                }
            }
            updated.references = unique(references)
            return updated
        }
    }

    @MainActor
    static func liveActivity(model: DockModel) -> [ActiveToolCall] {
        guard let owner = model.sessionID, let id = model.streamingMessageID,
            model.streamingMessageSessionID == owner,
            model.messages.contains(where: { $0.id == id })
        else { return [] }
        return model.streamingTurnActivity
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
    private var historyIndex = SessionPullRequestReferences.Index()
    private var activityIndex = SessionPullRequestReferences.Index()
    private var activityReferences: [GitHubItemReference] = []
    private var discoveryRevision: UInt64?
    private var activityGeneration: UInt64 = 0
    private var historyTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?

    init(api: PullRequestCenterAPI = .init(), details: PullRequestDetailStore = .shared) {
        self.api = api
        self.details = details
    }

    var visibleRecordChanges: AnyPublisher<[String: PullRequestRecord], Never> {
        $references.combineLatest(details.$records)
            .map { references, records in
                Dictionary(
                    references.compactMap { reference in records[reference.id].map { (reference.id, $0) } },
                    uniquingKeysWith: { first, _ in first })
            }
            .removeDuplicates().dropFirst().eraseToAnyPublisher()
    }

    func scheduleHistoryDiscovery(_ model: DockModel) {
        historyTask?.cancel()
        // The messages publisher fires before the model commits its array and revision.
        historyTask = Task { [weak self, weak model] in
            guard let model, !Task.isCancelled else { return }
            await self?.discover(messages: model.messages, revision: model.messagesRevision)
        }
        scheduleActivityDiscovery(model)
    }

    func scheduleActivityDiscovery(_ model: DockModel) {
        activityTask?.cancel()
        activityTask = Task { [weak self, weak model] in
            guard let model, !Task.isCancelled else { return }
            await self?.discoverActivity(
                SessionPullRequestReferences.liveActivity(model: model), revision: model.messagesRevision)
        }
    }

    func cancelDiscovery() {
        historyTask?.cancel()
        activityTask?.cancel()
    }

    func discover(messages: [ChatMessage], revision: UInt64) async {
        guard !Task.isCancelled else { return }
        startDiscovery(revision: revision)
        let messages = messages.map(SessionPullRequestReferences.Message.init)
        guard let index = await historyIndex.scan(messages: messages), !Task.isCancelled,
            discoveryRevision == revision
        else { return }
        historyIndex = index
        publishReferences()
    }

    func discoverActivity(_ activity: [ActiveToolCall], revision: UInt64) async {
        guard !Task.isCancelled else { return }
        startDiscovery(revision: revision)
        activityGeneration &+= 1
        let generation = activityGeneration
        guard let index = await activityIndex.scan(activity: activity), !Task.isCancelled,
            discoveryRevision == revision, activityGeneration == generation
        else { return }
        activityIndex = index
        activityReferences = SessionPullRequestReferences.unique(activityReferences + index.references)
        publishReferences()
    }

    private func startDiscovery(revision: UInt64) {
        guard discoveryRevision != revision else { return }
        discoveryRevision = revision
        activityReferences = []
    }

    private func publishReferences() {
        let found = SessionPullRequestReferences.unique(historyIndex.references + activityReferences)
        if references != found { references = found }
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
    @Environment(\.dockHostVisible) private var hostVisible
    let model: DockModel
    let workflow: DeveloperWorkflowModel
    /// Its `processes` follow the current session; the composer's process strip keeps them polled.
    let control: ControlCenterModel
    let repositoryPath: String?
    let onViewAllChanges: () -> Void
    let onViewPullRequest: (GitHubItemReference) async -> Bool
    let onRefreshChanges: () async -> Void
    let onViewAllOutputs: () -> Void
    let onViewTimeline: () -> Void
    let onRespondInChat: () -> Void
    let onViewPin: (PinnedMessage) async -> Bool
    @StateObject private var rail = SessionPullRequestRailModel()
    @StateObject private var outputs = SessionRailOutputsModel()
    @State private var refreshID = UUID()
    @State private var presentationRevision = 0
    @State private var lastOutputsRefreshID: UUID?
    @State private var contextFiles: (sessionID: String, files: [SessionContextFile])?
    @State private var lineSummary: RepositoryChangeLineSummary?
    @State private var lineSnapshot: RepositoryChangeSnapshot?
    @State private var checkpointForRestore: RestoreCheckpoint?
    @State private var plans: (sessionID: String, plans: [SessionPlan])?

    private var changes: SessionRailChangeSummary? {
        .make(path: repositoryPath, repository: workflow.repository, changes: workflow.changes)
    }

    private var summary: SessionRailSummary {
        var summary = SessionRailSummary.make(
            model: model, repositoryPath: repositoryPath, repository: workflow.repository,
            outputs: outputs.snapshot, outputsError: outputs.error,
            contextFiles: contextFiles?.sessionID == model.navigationSessionID ? contextFiles?.files ?? [] : [],
            processes: control.processes, checkpoints: control.restoreCheckpoints)
        summary.isRestoringCheckpoint = control.restoreCheckpointState.isPending
        if plans?.sessionID == model.navigationSessionID { summary.plans = plans?.plans ?? [] }
        return summary
    }

    var body: some View {
        let _ = presentationRevision
        ScrollView {
            SessionRailCard(
                repositoryName: repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                repositoryPath: repositoryPath,
                changes: changes, lines: lineSnapshot == workflow.changes ? lineSummary : nil,
                changesUnavailable: repositoryPath == workflow.repository.path && workflow.repository.isStale,
                references: rail.references, records: rail.details.records, failures: rail.failures,
                isRefreshing: rail.isRefreshing || workflow.isRefreshing || outputs.isRefreshing,
                onRefresh: { refreshID = UUID() },
                onViewAllChanges: onViewAllChanges, onViewPullRequest: onViewPullRequest,
                summary: summary, onViewAllOutputs: onViewAllOutputs,
                onOpenOutput: { SessionMessageTabs.shared.open(.output($0), in: WorkspaceIdentity.session(model)) },
                onRespondInChat: onRespondInChat, onViewPin: onViewPin, onViewTimeline: onViewTimeline,
                onRestoreCheckpoint: { checkpointForRestore = $0 },
                onOpenPlan: { plan in
                    FilePreviewCenter.shared.planRequest = plan.path
                    SessionMessageTabs.shared.open(
                        .file(URL(fileURLWithPath: plan.path)), in: WorkspaceIdentity.session(model))
                },
                onTrackPlan: {
                    model.attachChatContext(SessionPlans.trackProgressContext(path: $0.path, title: $0.title))
                },
                onUnlinkPlan: { plan in
                    guard let id = model.navigationSessionID else { return }
                    LinkedPlans.set(plan.path, linked: false, sessionID: id)
                    if let current = plans, current.sessionID == id {
                        plans = (id, current.plans.filter { $0.path != plan.path })
                    }
                }
            )
            .environment(\.sessionPreviewWorkspace, WorkspaceIdentity.session(model))
            .dockPadding(16)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .onReceive(SessionRailSummary.presentationChanges(model: model, workflow: workflow, control: control)) { _ in
            presentationRevision &+= 1
        }
        .onReceive(rail.visibleRecordChanges) { _ in presentationRevision &+= 1 }
        .onAppear { rail.scheduleHistoryDiscovery(model) }
        .onReceive(model.$messages.dropFirst()) { _ in rail.scheduleHistoryDiscovery(model) }
        .onReceive(
            model.activityPresentation.$revision.map { [model] _ in
                SessionPullRequestReferences.liveActivity(model: model)
            }
            .removeDuplicates().dropFirst()
        ) { _ in rail.scheduleActivityDiscovery(model) }
        .onDisappear { rail.cancelDiscovery() }
        .task(id: rail.references.map(\.id) + [refreshID.uuidString]) { await rail.refresh() }
        .task(id: [repositoryPath ?? "", refreshID.uuidString]) { await onRefreshChanges() }
        .task(id: [
            refreshID.uuidString, String(model.isSending), String(model.isRestoringSession),
            String(model.isHermesConnected),
        ]) {
            guard !model.isRestoringSession, !model.isSending, model.isHermesConnected,
                let id = model.navigationSessionID
            else { return }
            let force = lastOutputsRefreshID != nil && lastOutputsRefreshID != refreshID
            lastOutputsRefreshID = refreshID
            let session = HermesSession(
                id: id, profileID: model.sessionProfileID ?? model.profileScopeID,
                title: model.currentSessionTitle ?? "Session", preview: "", startedAt: nil,
                updatedAt: model.messages.last?.timestamp, messageCount: model.messages.count,
                source: HermesFeatureIDs.sessionSource)
            control.refreshCheckpoints(sessionID: id)
            async let pins: Void = model.refreshMessagePins()
            async let context = model.fetchSessionContextDetails()
            await outputs.refresh(session: session) {
                let results = await ArtifactIndexLoader.load(
                    sessions: [session], index: .shared, owner: ObjectIdentifier(model), force: force,
                    messages: { session, offset in try await model.artifactMessages(for: session, offset: offset) })
                return results.first
                    ?? .init(sessionID: id, profileID: session.profileID, records: [], error: "Outputs unavailable")
            }
            await pins
            // A missing manifest keeps the last one for this session rather than blanking the section.
            if let files = await context?.files, model.navigationSessionID == id { contextFiles = (id, files) }
        }
        .task(id: [model.navigationSessionID ?? "", repositoryPath ?? "", refreshID.uuidString, String(hostVisible)]) {
            guard hostVisible else { return }
            guard let id = model.navigationSessionID else {
                plans = nil
                return
            }
            let workspace = repositoryPath
            var loader = SessionPlans.Loader()
            var lastRevision: UInt64?
            while !Task.isCancelled {
                let revision = model.messagesRevision
                let texts = lastRevision == revision ? nil : model.messages.map(\.text)
                let linked = LinkedPlans.paths(sessionID: id)
                let tasks = model.planTasks
                let worker = Task.detached(priority: .utility) { [loader] in
                    var updated = loader
                    let found = updated.load(workspace: workspace, newTexts: texts, linked: linked, tasks: tasks)
                    return (updated, found)
                }
                let (updated, found) = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, model.navigationSessionID == id else { return }
                loader = updated
                lastRevision = revision
                if plans?.sessionID != id || plans?.plans != found { plans = (id, found) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: workflow.changes) {
            guard changes != nil, let repositoryPath, let snapshot = workflow.changes else { return }
            let lines = await RepositoryService.changeLineSummary(path: repositoryPath, changes: snapshot)
            guard !Task.isCancelled else { return }
            lineSummary = lines
            lineSnapshot = snapshot
        }
        .confirmationDialog(
            "Restore Session Checkpoint?",
            // The rail only begins a restore on confirm, so dismissing has nothing to cancel.
            isPresented: Binding(get: { checkpointForRestore != nil }, set: { if !$0 { checkpointForRestore = nil } })
        ) {
            if let checkpoint = checkpointForRestore {
                Button("Restore Checkpoint", role: .destructive) {
                    checkpointForRestore = nil
                    Task {
                        guard await control.restoreCheckpoint(checkpoint) else { return }
                        // Hermes rewinds the transcript along with the files; reload it.
                        await model.refreshCurrentSession()
                        refreshID = UUID()
                    }
                }
            }
            Button("Cancel", role: .cancel) { checkpointForRestore = nil }
        } message: {
            Text(
                "Hermes will restore this workspace’s files to this checkpoint and rewind the latest turn. Your own edits are kept."
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session rail")
    }
}

struct SessionRailCard: View {
    let repositoryName: String?
    var repositoryPath: String? = nil

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
    var summary = SessionRailSummary()
    var onViewAllOutputs: () -> Void = {}
    var onOpenOutput: (ArtifactRecord) -> Void = { _ in }
    var onRespondInChat: () -> Void = {}
    var onViewPin: (PinnedMessage) async -> Bool = { _ in false }
    var onViewTimeline: () -> Void = {}
    var onRestoreCheckpoint: (RestoreCheckpoint) -> Void = { _ in }
    var onOpenPlan: (SessionPlan) -> Void = { _ in }
    var onTrackPlan: (SessionPlan) -> Void = { _ in }
    var onUnlinkPlan: (SessionPlan) -> Void = { _ in }
    @State private var expandedChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(repositoryName ?? "Session overview")
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if isRefreshing {
                    DockLoadingIndicator().controlSize(.mini).frame(width: 24, height: 24)
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
            SessionRailSummarySections(
                summary: summary, onViewAllOutputs: onViewAllOutputs, onOpenOutput: onOpenOutput,
                onRespondInChat: onRespondInChat, onViewPin: onViewPin, onViewTimeline: onViewTimeline,
                onRestoreCheckpoint: onRestoreCheckpoint, onOpenPlan: onOpenPlan, onTrackPlan: onTrackPlan,
                onUnlinkPlan: onUnlinkPlan)
            if let changes {
                DisclosureGroup(isExpanded: $expandedChanges) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let repositoryPath {
                            SessionRailExpandedContent {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(changes.files) { file in
                                        SessionRailFileQuickView(path: repositoryPath, file: file)
                                    }
                                }
                            }
                        }
                        Button("View all changes", action: onViewAllChanges)
                            .buttonStyle(.dockLink).dockPadding(.top, 4)
                    }
                    .dockPadding(.top, 8)
                } label: {
                    changesRow(changes)
                }
                .disclosureGroupStyle(DockDisclosureGroupStyle(alignment: .top, animatesExpansion: false))
                .accessibilityIdentifier("session-rail.changes")
            } else if changesUnavailable {
                Text("Changes unavailable. Refresh to retry.")
                    .dockFont(.body).foregroundStyle(Color.dockWarning)
            }
            if !references.isEmpty {
                SessionRailSummarySection(title: "Pull requests", icon: .gitPullRequest, count: references.count) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(references) { reference in
                            SessionRailPullRequestItem(
                                reference: reference, record: records[reference.id], failure: failures[reference.id],
                                onViewPullRequest: onViewPullRequest)
                        }
                    }
                }
            } else if changes == nil && !changesUnavailable && summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRefreshing ? "Loading session overview…" : "Nothing here yet")
                        .dockFont(.body, weight: .semibold)
                    Text("Session details will appear here.")
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 16)
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
                changeCounts(changes).dockPadding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Show local changes in \(changes.repositoryName)")
        .accessibilityLabel("Changes, \(changes.fileCount) changed files in \(changes.repositoryName)")
    }

    private var changesLabel: some View {
        HStack(spacing: 8) {
            DockIcon(.gitDiff, size: 14, color: .dockSecondaryText)
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
}

/// Every expanded rail section fits short content and scrolls overflow within the same cap.
struct SessionRailExpandedContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    /// Sized in the same layout pass as its content: the scroll view's ideal height is the
    /// content's, capped at 280. A measured @State height started at 1pt, so a disclosure
    /// animated open to nothing and then snapped to the real height.
    var body: some View {
        ScrollView(.vertical) {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SessionRailFileQuickView: View {
    let path: String
    let file: RepositoryFileChange
    @Environment(\.sessionPreviewWorkspace) private var previewWorkspace

    var body: some View {
        Button {
            guard let previewWorkspace,
                let url = RepositoryService.documentURL(repositoryPath: path, filePath: file.path)
            else { return }
            SessionMessageTabs.shared.open(.file(url), in: previewWorkspace)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let image = ArtifactFileIcon.image(for: name) {
                        Image(nsImage: image).renderingMode(.original)
                            .resizable().interpolation(.high).scaledToFit()
                    } else {
                        DockIcon(.file, size: 14, color: .dockSecondaryText)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1).truncationMode(.middle)
                    if !directory.isEmpty {
                        Text(directory).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                Text(statusLetter).dockFont(.metadata, weight: .semibold).foregroundStyle(statusColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.dockHover)
        .help("\(file.path) · \(file.isStaged ? "Staged" : "Working tree") · \(file.status.rawValue.capitalized)")
        .accessibilityLabel("\(file.path), \(file.status.rawValue)\(file.isStaged ? ", staged" : "")")
    }

    private var name: String { (file.path as NSString).lastPathComponent }
    private var directory: String { (file.path as NSString).deletingLastPathComponent }

    private var statusLetter: String {
        switch file.status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        case .unknown: "?"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .added, .untracked: .dockSuccess
        case .deleted, .conflicted: .dockDestructive
        case .modified, .renamed: .dockWarning
        case .unknown: .dockSecondaryText
        }
    }
}
