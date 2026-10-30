import SwiftUI

/// Shared, popover-native source-control browser used by both global Source Control
/// and the session inspector. The repository remains the source of truth; this
/// view renders Git state, explicit index/commit actions, and read-only diffs.
struct RepositoryChangesBrowser: View {
    @ObservedObject var model: DockModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    let projectPath: String?
    let onRefresh: () async -> Void
    var onSelectProjectFolder: (() -> Void)?
    var onSelectFile: ((RepositoryFileChange) -> Void)? = nil
    var selectedFilePath: String? = nil

    var isInspector = false
    /// Session surfaces show the branch under the chat composer instead.
    var showsBranch = true

    @Environment(\.expandedReviewRouter) private var reviewRouter
    @State private var showingReview = false
    @State private var diffs: [String: RepositoryDiff] = [:]
    @State private var expandedFileIDs: Set<String> = []
    @State private var loadingFileIDs: Set<String> = []
    @State private var commitMessages: [String: String] = [:]
    @State private var isCommitsExpanded = true
    @State private var expandedCommitIDs: Set<String> = []
    @State private var commitDetails: [String: RepositoryCommitDetail] = [:]
    @State private var failedCommitDetailIDs: Set<String> = []
    @State private var allFilesCommitIDs: Set<String> = []
    @State private var pendingRemoteAction: String?
    @State private var hoveredFileID: String?
    @State private var discardRequest: [RepositoryFileChange]?
    @FocusState private var focusedStageFileID: String?
    @State private var diffGeneration = UUID()
    @State private var isCommitPopoverPresented = false

    private var reviewScope: String { WorkspaceIdentity.session(model) + ":repository:" + (projectPath ?? "") }
    private var revisionNotes: RevisionNoteStore { ReviewDraftStore.shared.notes(key: reviewScope) }
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    private var actionsDisabled: Bool {
        workflow.isRefreshing || workflow.isMutatingSourceControl || workflow.changes?.error != nil
            || projectPath != workflow.repository.path
    }
    @State private var isStagedExpanded = true
    @State private var isChangesExpanded = true

    var body: some View {
        // The workflow is shared; never show another project's snapshot (e.g. a new chat with no folder).
        let isStale = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } != workflow.repository.path
        if let changes = workflow.changes, let error = changes.error, !isStale {
            emptyState(icon: .warningCircle, title: "Git status unavailable", detail: error)
        } else if let changes = workflow.changes, workflow.repository.isGitRepository, projectPath != nil, !isStale {
            browser(changes)
        } else if let projectPath {
            let isLoading = workflow.isRefreshing || isStale
            emptyState(
                icon: isLoading ? .arrowsClockwise : .folder,
                title: isLoading ? "Inspecting project" : "Project is not a Git repository",
                detail: isLoading
                    ? projectPath
                    : "\(projectPath) is available as a local project folder, but it has no Git working tree to inspect."
            )
        } else {
            SessionProjectRequiredState(onSelectProject: onSelectProjectFolder)
        }
    }

    private func browser(_ changes: RepositoryChangeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceControlHeader(changes)
            HStack(spacing: DockSpacing.control) {
                Button {
                    if let projectPath, let reviewRouter,
                        reviewRouter.present(
                            LocalReviewWorkspace(closeAction: { reviewRouter.close() }, path: projectPath, model: model)
                        )
                    {
                        return
                    }
                    showingReview = true
                } label: {
                    DockIconLabel("Review comparisons", icon: .gitDiff)
                }
                .buttonStyle(.dockCompact)
                .help("Review working-tree, staged, branch, or commit comparisons")
                Spacer()
                if !showsBranch { refreshButton }
            }.dockPadding(.vertical, 8)
                .dockSheet(isPresented: $showingReview) {
                    if let projectPath {
                        LocalReviewWorkspace(path: projectPath, model: model).modifier(ReviewSheetContext())
                    }
                }

            if !isInspector, case .available = workflow.githubIntegrationState {
                pullRequestsSection
            }

            if changes.files.isEmpty {
                emptyState(
                    icon: .checkCircle, title: "Working tree clean",
                    detail: "No staged, unstaged, or untracked files were found.")
            } else {
                let stagedFiles = changes.files.filter(\.isStaged)
                let worktreeFiles = changes.files.filter { !$0.isStaged }

                changeGroup(title: "Staged Changes", files: stagedFiles, isExpanded: $isStagedExpanded, staged: true)
                changeGroup(title: "Changes", files: worktreeFiles, isExpanded: $isChangesExpanded, staged: false)
            }
            RepositoryStashSection(workflow: workflow, actionsDisabled: actionsDisabled) { action in perform(action) }
                .id(workflow.repository.path)
            commitsSection
        }
        .confirmationDialog(
            discardTitle, isPresented: Binding(get: { discardRequest != nil }, set: { if !$0 { discardRequest = nil } })
        ) {
            Button(discardRequest?.count == 1 ? "Discard Changes" : "Discard All Changes", role: .destructive) {
                if let files = discardRequest { perform(.discard(files)) }
                discardRequest = nil
            }
            Button("Cancel", role: .cancel) { discardRequest = nil }
        } message: {
            Text(discardMessage)
        }
        .onChange(of: workflow.repository.path) { _, _ in
            diffs = [:]
            expandedFileIDs = []
            loadingFileIDs = []
            expandedCommitIDs = []
            commitDetails = [:]
            failedCommitDetailIDs = []
            diffGeneration = UUID()
        }
        .onChange(of: changes) { _, newChanges in
            // Cached diffs go stale with the working tree; refetch the open ones.
            let liveIDs = Set(newChanges.files.map(\.id))
            diffs = [:]
            loadingFileIDs = []
            diffGeneration = UUID()
            expandedFileIDs.formIntersection(liveIDs)
            for file in newChanges.files where expandedFileIDs.contains(file.id) { loadDiff(for: file) }
        }
    }

    private func changeGroup(
        title: String,
        files: [RepositoryFileChange],
        isExpanded: Binding<Bool>,
        staged: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DockSectionHeader(
                title: title, count: files.count, isExpanded: isExpanded, style: style,
                icon: staged ? .checkCircle : .pencilSimple,
                tint: .dockSecondaryText
            ) {
                if staged {
                    DockIconButton(
                        icon: .check, label: "Commit staged changes",
                        isBusy: workflow.isMutatingSourceControl && pendingRemoteAction == nil, size: 22, style: style
                    ) {
                        isCommitPopoverPresented = true
                    }
                    .disabled(actionsDisabled || files.isEmpty || workflow.changes?.conflictedCount ?? 0 > 0)
                    .dockPopover(isPresented: $isCommitPopoverPresented, arrowEdge: .bottom) { commitPopover }
                }
                DockIconButton(
                    icon: staged ? .minus : .plus, label: staged ? "Unstage all changes" : "Stage all changes",
                    size: 22, style: style
                ) {
                    perform(staged ? .unstage(files) : .stage(files))
                }
                .disabled(actionsDisabled || files.isEmpty)
            }
            .contextMenu {
                if staged {
                    Button("Commit Staged…") { isCommitPopoverPresented = true }
                        .disabled(actionsDisabled || files.isEmpty || workflow.changes?.conflictedCount ?? 0 > 0)
                    Button("Unstage All Changes") { perform(.unstage(files)) }.disabled(
                        actionsDisabled || files.isEmpty)
                } else {
                    Button("Stage All Changes") { perform(.stage(files)) }.disabled(actionsDisabled || files.isEmpty)
                    Button("Discard All Changes…", role: .destructive) {
                        discardRequest = files.filter(Self.isDiscardable)
                    }
                    .disabled(actionsDisabled || !files.contains(where: Self.isDiscardable))
                }
            }
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 0) {
                    if files.isEmpty {
                        Text(staged ? "No staged changes" : "No unstaged changes")
                            .dockFont(.body).foregroundStyle(Color.dockMetadataText)
                            .dockPadding(.horizontal, 8).dockPadding(.vertical, 6)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(files) { file in fileRow(file) }
                    }
                }
                .dockPadding(.leading, 12)
            }
        }
        .dockPadding(.top, 8)
    }

    private var commitPopover: some View {
        let path = workflow.repository.path
        let message = Binding(get: { commitMessages[path, default: ""] }, set: { commitMessages[path] = $0 })
        let isEmpty = message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Text("Commit \(workflow.changes?.stagedCount ?? 0) staged to \(workflow.repository.branch)")
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
            TextField("Message", text: message, axis: .vertical)
                .textFieldStyle(.dockGlass)
                .dockFont(.body)
                .lineLimit(2...6)
                .accessibilityLabel("Commit message")
            Button {
                isCommitPopoverPresented = false
                perform(.commit(message.wrappedValue))
            } label: {
                DockActionLabel(
                    title: "Commit", pendingTitle: "Committing…", isPending: workflow.isMutatingSourceControl
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dockPrimary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actionsDisabled || isEmpty)
        }
        .dockPadding(12)
        .frame(width: 300)
    }

    private var commitsSection: some View {
        let rows = RepositoryCommitGraph.layout(workflow.commits)
        return VStack(alignment: .leading, spacing: 0) {
            DockSectionHeader(
                title: "Graph", count: workflow.commits.count, isExpanded: $isCommitsExpanded, style: style,
                icon: .gitFork, tint: .dockSecondaryText
            ) {
                remoteActions
            }
            if isCommitsExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = workflow.commitsError {
                        Text(error).dockFont(.body).foregroundStyle(Color.dockWarning).dockPadding(8)
                    } else if workflow.commits.isEmpty {
                        Text(workflow.isRefreshing ? "Loading commits…" : "No commits on this branch yet")
                            .dockFont(.body).foregroundStyle(Color.dockMetadataText).dockPadding(8)
                    }
                    if let ahead = workflow.repository.aheadCount, let behind = workflow.repository.behindCount {
                        HStack(spacing: 8) {
                            if ahead == 0 && behind == 0 {
                                DockIconLabel("Up to date with upstream", icon: .checkCircle)
                            } else {
                                if behind > 0 { DockIconLabel("\(behind) to pull", icon: .arrowDown) }
                                if ahead > 0 { DockIconLabel("\(ahead) to push", icon: .arrowUp) }
                            }
                            Text("· as of last fetch")
                        }
                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        .dockPadding(.horizontal, 8).dockPadding(.bottom, 6)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(zip(workflow.commits, rows)), id: \.0.id) { commit, row in
                            commitRow(commit, row: row)
                        }
                    }
                    if workflow.commits.count == 50 {
                        Text("Showing the latest 50 commits").dockFont(.metadata).foregroundStyle(
                            Color.dockMetadataText
                        ).dockPadding(8)
                    }
                }
                .dockPadding(.leading, 12)
            }
        }
        .dockPadding(.top, 12)
    }

    /// Fetch, pull, and push. Pull and push need an upstream branch to target.
    @ViewBuilder
    private var remoteActions: some View {
        let hasUpstream = workflow.repository.aheadCount != nil
        remoteButton(.fetch, id: "fetch", icon: .cloudArrowDown, label: "Fetch from all remotes")
        if hasUpstream {
            let behind = workflow.repository.behindCount ?? 0
            let ahead = workflow.repository.aheadCount ?? 0
            remoteButton(
                .pull, id: "pull", icon: .arrowDown,
                label: behind > 0
                    ? "Pull \(behind) commit\(behind == 1 ? "" : "s") (fast-forward only)" : "Pull (fast-forward only)")
            remoteButton(
                .push, id: "push", icon: .arrowUp,
                label: ahead > 0 ? "Push \(ahead) commit\(ahead == 1 ? "" : "s")" : "Nothing to push"
            )
            .disabled(actionsDisabled || ahead == 0)
        }
    }

    private func remoteButton(_ action: RepositorySourceControlAction, id: String, icon: Ph, label: String) -> some View
    {
        DockIconButton(icon: icon, label: label, isBusy: pendingRemoteAction == id, size: 22, style: style) {
            pendingRemoteAction = id
            perform(action) { pendingRemoteAction = nil }
        }
        .disabled(actionsDisabled)
    }

    private func commitRow(_ commit: RepositoryCommit, row: RepositoryCommitGraphRow) -> some View {
        // Text starts right after this row's own lanes, so it nests in and out as branches open and merge.
        let graphWidth = CGFloat(row.width) * RepositoryCommitGraphLanes.laneSpacing + 6
        let isExpanded = expandedCommitIDs.contains(commit.id)
        let references = RepositoryCommitReference.parse(commit.references)
        let accent = RepositoryCommitGraphPalette.accent(row.color)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expandedCommitIDs.insert(commit.id).inserted {
                    loadCommitDetail(commit)
                } else {
                    expandedCommitIDs.remove(commit.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(commit.subject).dockFont(.body).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                        .layoutPriority(1)
                    ForEach(references.prefix(3)) { RepositoryCommitReferencePill(reference: $0, accent: accent) }
                    if references.count > 3 {
                        Text("+\(references.count - 3)").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    }
                    Spacer(minLength: 4)
                    Text(commit.author.split(separator: " ").first.map(String.init) ?? commit.author)
                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                }
                .dockPadding(.trailing, 6)
                .frame(minHeight: RepositoryCommitGraphLanes.rowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help(
                "\(commit.subject)\n\(commit.author) · \(commit.date.formatted(.relative(presentation: .named))) · \(commit.id.prefix(7))"
            )
            .accessibilityLabel(
                "\(commit.subject), by \(commit.author)\(references.isEmpty ? "" : ", " + references.map(\.name).joined(separator: ", ")). \(isExpanded ? "Collapse" : "Expand") commit details"
            )
            if isExpanded { commitDetail(commit, references: references, accent: accent) }
        }
        .dockPadding(.leading, graphWidth)
        .background(alignment: .leading) {
            RepositoryCommitGraphLanes(
                row: row, isHead: references.contains(where: \.isHead), isMerge: commit.parents.count > 1
            )
            .frame(width: graphWidth)
        }
        .dockPadding(.horizontal, 8)
    }

    @ViewBuilder
    private func commitDetail(
        _ commit: RepositoryCommit, references: [RepositoryCommitReference], accent: DockAccentColor
    ) -> some View {
        let detail = commitDetails[commit.id]
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.author)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                if let email = detail?.email, !email.isEmpty {
                    Text(email)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "\(commit.date.formatted(date: .abbreviated, time: .shortened)) · \(commit.date.formatted(.relative(presentation: .named)))"
                )
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            if let body = detail?.body, body != commit.subject {
                Text(body).dockFont(.body).foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !commit.parents.isEmpty {
                HStack(spacing: 4) {
                    Text(commit.parents.count > 1 ? "Merge of" : "Parent").dockFont(.metadata)
                    ForEach(Array(commit.parents.enumerated()), id: \.offset) { index, parent in
                        if index > 0 { Text(", ") }
                        DockCommitIdentifier(revision: parent)
                    }
                }
                .foregroundStyle(Color.dockMetadataText)
                .textSelection(.enabled)
            }
            if references.count > 3 {
                DockChipFlow { ForEach(references) { RepositoryCommitReferencePill(reference: $0, accent: accent) } }
            }
            DockChipFlow(spacing: 8) {
                HStack(spacing: 8) {
                    DockCommitIdentifier(revision: commit.id, length: 10)
                        .foregroundStyle(Color.dockSecondaryText)
                        .textSelection(.enabled)
                        .help(commit.id)
                    DockCopyButton(commit.id, label: "Copy hash", accessibilityLabel: "Copy commit hash")
                        .buttonStyle(.dockCompact)
                }
                if let repository = workflow.githubRepository {
                    Button {
                        NSWorkspace.shared.open(repository.webURL.appendingPathComponent("commit/\(commit.id)"))
                    } label: {
                        DockIconLabel("Open on GitHub", icon: .arrowSquareOut)
                    }
                    .buttonStyle(.dockCompact)
                }
            }
            Divider().overlay(Color.dockBorderLight)
            if let detail {
                commitFiles(commit, detail: detail)
            } else if failedCommitDetailIDs.contains(commit.id) {
                Text("Changed files are unavailable for this commit.").dockFont(.metadata).foregroundStyle(
                    Color.dockWarning)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading changed files…").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
            }
        }
        .dockPadding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).dockSurfaceFill(
                Color.dockSurface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).stroke(
                Color.dockBorderLight, lineWidth: 0.5)
        )
        .dockPadding(.top, 2).dockPadding(.bottom, 8)
    }

    @ViewBuilder
    private func commitFiles(_ commit: RepositoryCommit, detail: RepositoryCommitDetail) -> some View {
        let additions = detail.files.compactMap(\.additions).reduce(0, +)
        let deletions = detail.files.compactMap(\.deletions).reduce(0, +)
        let showsAll = allFilesCommitIDs.contains(commit.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(
                    detail.files.isEmpty
                        ? "No files changed" : "\(detail.files.count) file\(detail.files.count == 1 ? "" : "s") changed"
                )
                .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 4)
                if !detail.files.isEmpty {
                    Text("+\(additions)").foregroundStyle(Color.dockSuccess)
                    Text("−\(deletions)").foregroundStyle(Color.dockDestructive)
                }
            }
            .dockFont(.metadata, weight: .semibold).monospacedDigit()
            .dockPadding(.bottom, 2)
            ForEach(showsAll ? detail.files : Array(detail.files.prefix(12))) { file in
                let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
                let directory = file.path.split(separator: "/").dropLast().joined(separator: "/")
                HStack(spacing: 6) {
                    if let icon = ArtifactFileIcon.image(for: name) {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                    } else {
                        DockIcon(.fileText, size: 14, color: .dockSecondaryText)
                    }
                    Text(name).dockFont(.metadata).foregroundStyle(Color.dockPrimaryText).lineLimit(1).truncationMode(
                        .middle
                    ).layoutPriority(1)
                    if !directory.isEmpty {
                        Text(directory).dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    if let added = file.additions, let deleted = file.deletions {
                        Text("+\(added)").foregroundStyle(Color.dockSuccess)
                        Text("−\(deleted)").foregroundStyle(Color.dockDestructive)
                    } else {
                        Text("binary").foregroundStyle(Color.dockMetadataText)
                    }
                }
                .dockFont(.metadata).monospacedDigit()
                .frame(minHeight: 20)
                .help(file.path)
            }
            if detail.files.count > 12 && !showsAll {
                Button("Show all \(detail.files.count) files") { allFilesCommitIDs.insert(commit.id) }
                    .buttonStyle(.dockLink)
                    .dockPadding(.top, 2)
            }
        }
    }

    private func loadCommitDetail(_ commit: RepositoryCommit) {
        guard commitDetails[commit.id] == nil else { return }
        failedCommitDetailIDs.remove(commit.id)
        let path = workflow.repository.path
        Task {
            let detail = await RepositoryService.commitDetail(path: path, hash: commit.id)
            guard path == workflow.repository.path else { return }
            if let detail { commitDetails[commit.id] = detail } else { failedCommitDetailIDs.insert(commit.id) }
        }
    }

    private var pullRequestsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("PULL REQUESTS")
                    .dockFont(.compactStatus, weight: .bold, design: .monospaced)
                    .tracking(1.05)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 8)
                Text("\(workflow.githubPullRequests.count)")
                    .dockFont(.metadata, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockAccent)
            }
            .frame(minHeight: 34)

            if workflow.githubPullRequests.isEmpty {
                Text("No open pull requests")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockPadding(.vertical, 10)
            } else {
                ForEach(workflow.githubPullRequests.prefix(5)) { pullRequest in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(pullRequest.isDraft ? Color.dockMetadataText : Color.dockSuccessFill)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(pullRequest.number)  \(pullRequest.title)")
                                .dockFont(.metadata, weight: .medium)
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                            if let metadata = pullRequest.metadataLabel {
                                Text(metadata)
                                    .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                                    .foregroundStyle(Color.dockMetadataText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if let url = pullRequest.webURL {
                            Link("Open", destination: url)
                                .buttonStyle(.dockLink)
                                .foregroundStyle(Color.dockAccent)
                        }
                    }
                    .dockPadding(.vertical, 8)
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                }
            }
        }
        .dockPadding(.top, 12)
    }

    private var refreshButton: some View {
        DockIconButton(
            icon: .arrowsClockwise, label: "Refresh source control", isBusy: workflow.isRefreshing, style: style
        ) {
            Task { await onRefresh() }
        }
        .disabled(workflow.isMutatingSourceControl)
    }

    @ViewBuilder
    private func sourceControlHeader(_ changes: RepositoryChangeSnapshot) -> some View {
        let notice =
            workflow.sourceControlError
            ?? (changes.conflictedCount > 0 ? "Resolve conflicts, then stage the resolved files." : nil)
        if showsBranch || notice != nil || !isInspector {
            VStack(alignment: .leading, spacing: 9) {
                if showsBranch {
                    HStack(spacing: 8) {
                        DockIcon(.gitBranch)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockAccent)
                        Text(changes.branch)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        refreshButton
                    }
                }

                if let notice {
                    Text(notice)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                        .help(notice)
                }

                if !isInspector { githubConnectionRow }
            }
            .dockPadding(.bottom, 11)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        }
    }

    @ViewBuilder
    private var githubConnectionRow: some View {
        if workflow.isAuthenticatingGitHub || workflow.githubAuthenticationNotice?.hasPrefix("GitHub connected") == true
        {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    DockIcon(.checkCircle)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSuccess)
                    Text(workflow.githubAuthenticationNotice ?? "GitHub connected. Refreshing pull requests…")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 8)
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.dockAccent)
                }
                if let code = workflow.githubAuthenticationCode {
                    Text(code)
                        .dockFont(.pageTitle, weight: .bold, design: .monospaced)
                        .tracking(2.2)
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                        .accessibilityLabel("GitHub device code \(code)")
                }
            }
            .dockPadding(.vertical, 2)
        } else if workflow.isSigningOutGitHub {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.dockAccent)
                Text(workflow.githubAuthenticationNotice ?? "Signing out of GitHub…")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .frame(minHeight: 24)
        } else {
            switch workflow.githubIntegrationState {
            case .noRemote:
                EmptyView()
            case .notLoaded:
                githubStatusRow(icon: .arrowsClockwise, message: "GitHub status not loaded.", actionTitle: "Refresh") {
                    Task { await workflow.refreshGitHub() }
                }
            case .unavailable(let error):
                if case .unauthorized = error {
                    HStack(spacing: 7) {
                        DockIcon(.userGear)
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockWarning)
                        Text("GitHub sign-in required.")
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer(minLength: 8)
                        Button("SIGN IN") {
                            workflow.authenticateGitHub()
                        }
                        .buttonStyle(.dockCompact)
                        .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Color.dockAccent)
                    }
                    .frame(minHeight: 24)
                    if let notice = workflow.githubAuthenticationNotice {
                        Text(notice)
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockMetadataText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let code = workflow.githubAuthenticationCode {
                        Text(code)
                            .dockFont(.pageTitle, weight: .bold, design: .monospaced)
                            .tracking(2.2)
                            .foregroundStyle(Color.dockPrimaryText)
                            .textSelection(.enabled)
                            .dockPadding(.vertical, 2)
                            .accessibilityLabel("GitHub device code \(code)")
                    }
                } else {
                    githubStatusRow(icon: .warning, message: githubStatusMessage(for: error), actionTitle: "Retry") {
                        Task { await workflow.refreshGitHub() }
                    }
                }
            case .stale:
                githubStatusRow(icon: .warning, message: "Using last known GitHub data.", actionTitle: "Retry") {
                    Task { await workflow.refreshGitHub() }
                }
            case .available:
                if let github = workflow.githubRepository {
                    HStack(spacing: 7) {
                        DockIcon(.checkCircle, weight: .fill)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockSuccess)
                        Text("GitHub")
                            .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                            .foregroundStyle(Color.dockMetadataText)
                        Link(github.id, destination: github.webURL)
                            .buttonStyle(.dockLink)
                            .lineLimit(1)
                        Spacer()
                        sourceControlIcon(
                            workflow.isRefreshingGitHub ? .dotsThree : .arrowsClockwise, help: "Refresh GitHub"
                        ) {
                            Task { await workflow.refreshGitHub() }
                        }
                        .disabled(workflow.isRefreshingGitHub)
                        .accessibilityIdentifier(WorkflowAccessibilityIdentifier.changesRefreshGitHub)
                        Button("SIGN OUT") {
                            workflow.signOutGitHub()
                        }
                        .buttonStyle(.dockCompact)
                        .dockFont(.metadata, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Color.dockSecondaryText)
                    }
                }
            }
        }
    }

    private func githubStatusMessage(for error: GitHubCodeHostError) -> String {
        switch error {
        case .forbidden:
            "GitHub access to this repository is denied."
        case .repositoryNotFound:
            "GitHub repository was not found or is inaccessible."
        default:
            "GitHub is unavailable."
        }
    }

    private func githubStatusRow(
        icon: Ph,
        message: String,
        actionTitle: String = "Connect GitHub",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            DockIcon(icon)
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(Color.dockWarning)
            Text(message)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Button(workflow.isAuthenticatingGitHub ? "Connecting…" : actionTitle, action: action)
                .buttonStyle(.dockCompact)
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(Color.dockAccent)
                .disabled(workflow.isAuthenticatingGitHub)
        }
        .frame(minHeight: 24)
    }

    private func sourceControlIcon(_ systemName: Ph, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(systemName)
                .dockFont(.navigation, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(help)
    }

    private func fileRow(_ file: RepositoryFileChange) -> some View {
        let isExpanded = expandedFileIDs.contains(file.id)
        // The stage toggle stays laid out but only shows on hover or keyboard focus, keeping rows quiet at rest.
        let showsStageButton = hoveredFileID == file.id || focusedStageFileID == file.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    if let onSelectFile { onSelectFile(file) } else { toggle(file) }
                } label: {
                    fileRowLabel(file, showsSelection: selectedFilePath == file.id || isExpanded)
                }
                .buttonStyle(.dockHover)
                .help("\(file.path) · \(fileStatusDescription(for: file)) · Show diff")
                .accessibilityLabel("\(file.path), \(fileStatusDescription(for: file)). Show diff")
                Button {
                    perform(file.isStaged ? .unstage([file]) : .stage([file]))
                } label: {
                    DockIcon(file.isStaged ? .minus : .plus, size: 11, color: .dockSecondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .focused($focusedStageFileID, equals: file.id)
                .opacity(showsStageButton ? 1 : 0)
                .help("\(file.isStaged ? "Unstage" : "Stage") \(file.path)")
                .accessibilityLabel("\(file.isStaged ? "Unstage" : "Stage") \(file.path)")
                .disabled(actionsDisabled)
                Text(statusLetter(for: file))
                    .dockFont(.metadata, weight: .semibold, design: .monospaced)
                    .foregroundStyle(statusColor(for: file)).frame(width: 18)
                    .help(fileStatusDescription(for: file))
            }
            .onHover { hoveredFileID = $0 ? file.id : (hoveredFileID == file.id ? nil : hoveredFileID) }
            .contextMenu { fileContextMenu(file) }
            if onSelectFile == nil && isExpanded { diffCard(for: file) }
        }
    }

    @ViewBuilder
    private func diffCard(for file: RepositoryFileChange) -> some View {
        Group {
            if let diff = diffs[file.id] {
                let lines = Self.displayLines(diff.text)
                if lines.isEmpty {
                    diffNotice(
                        file.status == .untracked || file.status == .added
                            ? "Binary or empty file." : "No textual diff is available for this file.")
                } else {
                    SharedDiffView(
                        patch: diff.text, path: file.path,
                        contextLoader: file.status == .untracked
                            ? nil
                            : { lines in
                                try await RepositoryComparisonService.expandedPatch(
                                    path: projectPath ?? "", file: file.path,
                                    arguments: file.isStaged
                                        ? ["diff", "--no-ext-diff", "--cached"] : ["diff", "--no-ext-diff"],
                                    original: diff.text, lines: lines, renameSource: file.renameSource)
                            }, projectPath: projectPath,
                        comparison: projectPath.map {
                            DiffComparisonIdentity(
                                repository: $0, revision: workflow.repository.headRevision ?? "unavailable",
                                fingerprint: workflow.repositoryFingerprint ?? "")
                        }, revisionNotes: revisionNotes
                    )
                    .id(reviewScope + ":" + file.id)
                }
                if diff.isTruncated { diffNotice("Diff truncated for safe display.", color: .dockWarning) }
            } else if loadingFileIDs.contains(file.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
                .dockPadding(10)
            } else {
                diffNotice("This file has no readable diff.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).dockSurfaceFill(
                Color.dockSurface2)
        )
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).stroke(
                Color.dockBorderLight, lineWidth: 0.5)
        )
        .dockPadding(.top, 4)
        .dockPadding(.bottom, 8)
    }

    private func diffNotice(_ text: String, color: Color = .dockMetadataText) -> some View {
        Text(text)
            .dockFont(.metadata)
            .foregroundStyle(color)
            .dockPadding(.horizontal, 10)
            .dockPadding(.vertical, 8)
    }

    private static let maxDiffHeight: CGFloat = 360

    /// Hunks only: the `diff --git` / `index` / `---` / `+++` preamble repeats
    /// what the row already shows.
    static func displayLines(_ text: String) -> [PullRequestDiffLine] {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstHunk = rows.firstIndex(where: { $0.hasPrefix("@@") }) else { return [] }
        return rows[firstHunk...].enumerated().compactMap { offset, row in
            row.hasPrefix("\\ No newline") ? nil : PullRequestDiffLine(index: offset, text: String(row))
        }
    }

    private func fileRowLabel(_ file: RepositoryFileChange, showsSelection: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon = ArtifactFileIcon.image(for: fileName(for: file)) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                DockIcon(.fileText, size: 16, color: .dockSecondaryText)
            }
            Text(fileName(for: file))
                .dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if !fileDirectory(for: file).isEmpty {
                Text(fileDirectory(for: file))
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .dockPadding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(
            showsSelection ? Color.dockAccent.opacity(0.13) : .clear,
            in: DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius)
        )
        .contentShape(Rectangle())
    }

    /// Mirrors VS Code's Source Control item menu.
    @ViewBuilder
    private func fileContextMenu(_ file: RepositoryFileChange) -> some View {
        let url = URL(fileURLWithPath: workflow.repository.path).appendingPathComponent(file.path)
        Button("Open Changes") {
            if let onSelectFile { onSelectFile(file) } else if !expandedFileIDs.contains(file.id) { toggle(file) }
        }
        if file.status != .deleted {
            Button("Open File") { ExternalOpen.open(url) }
        }
        Divider()
        Button(file.isStaged ? "Unstage Changes" : "Stage Changes") {
            perform(file.isStaged ? .unstage([file]) : .stage([file]))
        }
        .disabled(actionsDisabled)
        if Self.isDiscardable(file) {
            Button("Discard Changes…", role: .destructive) { discardRequest = [file] }
                .disabled(actionsDisabled)
        }
        if file.status == .untracked {
            Button("Add to .gitignore") { perform(.ignore([file])) }
                .disabled(actionsDisabled)
        }
        Divider()
        Button("Copy Path") { copyToPasteboard(url.path) }
        Button("Copy Relative Path") { copyToPasteboard(file.path) }
        if file.status != .deleted {
            Button("Reveal in Finder") { ExternalOpen.reveal([url]) }
        }
    }

    private static func isDiscardable(_ file: RepositoryFileChange) -> Bool {
        !file.isStaged && file.status != .conflicted
    }

    private var discardTitle: String {
        guard let files = discardRequest else { return "" }
        return files.count == 1
            ? "Discard changes to \(fileName(for: files[0]))?" : "Discard changes to \(files.count) files?"
    }

    private var discardMessage: String {
        let untracked = discardRequest?.filter { $0.status == .untracked }.count ?? 0
        let tracked = (discardRequest?.count ?? 0) - untracked
        return [
            tracked > 0 ? "Unstaged edits will be lost. Staged changes are kept." : nil,
            untracked > 0 ? "Untracked files move to the Trash." : nil,
        ].compactMap(\.self).joined(separator: " ")
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func perform(_ action: RepositorySourceControlAction, completion: @escaping () -> Void = {}) {
        let path = workflow.repository.path
        Task {
            let succeeded = await workflow.applySourceControl(action, path: path, refresh: onRefresh)
            completion()
            if succeeded, case .commit(let submittedMessage) = action, commitMessages[path] == submittedMessage {
                commitMessages[path] = ""
            }
        }
    }

    private func fileName(for file: RepositoryFileChange) -> String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    private func fileDirectory(for file: RepositoryFileChange) -> String {
        file.path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func statusLetter(for file: RepositoryFileChange) -> String {
        switch file.status {
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        case .modified: "M"
        case .unknown: "?"
        }
    }

    private func fileStatusDescription(for file: RepositoryFileChange) -> String {
        let action: String
        switch file.status {
        case .added: action = "Added"
        case .deleted: action = "Deleted"
        case .renamed: action = "Renamed"
        case .untracked: action = "Untracked"
        case .conflicted: action = "Conflicted"
        case .modified: action = "Modified"
        case .unknown: action = "Unknown status"
        }
        return file.isStaged ? "Staged, \(action.lowercased())" : action
    }

    private func statusColor(for file: RepositoryFileChange) -> Color {
        if file.status == .conflicted { return .dockDestructive }
        if file.isStaged { return .dockAccent }
        if file.status == .untracked || file.status == .added { return .dockSuccess }
        if file.status == .deleted { return .dockDestructive }
        if file.status == .renamed { return DockCategoryTone.renamed.color }
        if file.status == .modified { return DockCategoryTone.modified.color }
        return .dockSecondaryText
    }

    private func toggle(_ file: RepositoryFileChange) {
        if expandedFileIDs.remove(file.id) == nil {
            expandedFileIDs.insert(file.id)
            if diffs[file.id] == nil { loadDiff(for: file) }
        }
    }

    private func loadDiff(for file: RepositoryFileChange) {
        guard loadingFileIDs.insert(file.id).inserted else { return }
        let path = workflow.repository.path
        let token = diffGeneration
        Task {
            let diff = await RepositoryService.diff(path: path, file: file)
            guard path == workflow.repository.path, token == diffGeneration else { return }
            loadingFileIDs.remove(file.id)
            diffs[file.id] = diff
        }
    }

    private func emptyState(icon: Ph, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockIconLabel(title, icon: icon).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockPadding(12)

    }
}
