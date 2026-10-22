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

    @Environment(\.expandedReviewRouter) private var reviewRouter
    @State private var showingReview = false
    @State private var diffs: [String: RepositoryDiff] = [:]
    @State private var expandedFileIDs: Set<String> = []
    @State private var loadingFileIDs: Set<String> = []
    @State private var commitMessages: [String: String] = [:]
    @State private var isCommitsExpanded = true
    @State private var expandedCommitIDs: Set<String> = []
    @State private var diffGeneration = UUID()
    @State private var isCommitPopoverPresented = false

    private var reviewScope: String { WorkspaceIdentity.session(model) + ":repository:" + (projectPath ?? "") }
    private var revisionNotes: RevisionNoteStore { ReviewDraftStore.shared.notes(key: reviewScope) }
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    private var actionsDisabled: Bool { workflow.isRefreshing || workflow.isMutatingSourceControl || projectPath != workflow.repository.path }
    @State private var isStagedExpanded = true
    @State private var isChangesExpanded = true

    var body: some View {
        if let changes = workflow.changes, workflow.repository.isGitRepository {
            browser(changes)
        } else if let projectPath {
            emptyState(
                icon: workflow.isRefreshing ? .arrowsClockwise : .folder,
                title: workflow.isRefreshing ? "Inspecting project" : "Project is not a Git repository",
                detail: workflow.isRefreshing ? projectPath : "\(projectPath) is available as a local project folder, but it has no Git working tree to inspect."
            )
        } else {
            SessionProjectRequiredState(onSelectProject: onSelectProjectFolder)
        }
    }

    private func browser(_ changes: RepositoryChangeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceControlHeader(changes)
            HStack {
                Button("Review comparisons") {
                    if let projectPath, let reviewRouter, reviewRouter.present(LocalReviewWorkspace(closeAction: { reviewRouter.close() }, path: projectPath, model: model)) { return }
                    showingReview = true
                }.buttonStyle(.dockCompact)
                if let projectPath { ProjectActionsMenu(path: projectPath, model: model) }
                Spacer()
            }.padding(.vertical, 8)
            .sheet(isPresented: $showingReview) {
                if let projectPath { LocalReviewWorkspace(path: projectPath, model: model).modifier(ReviewSheetContext()) }
            }

            if !isInspector, case .available = workflow.githubIntegrationState {
                pullRequestsSection
            }

            if changes.files.isEmpty {
                emptyState(icon: .checkCircle, title: "Working tree clean", detail: "No staged, unstaged, or untracked files were found.")
            } else {
                let stagedFiles = changes.files.filter(\.isStaged)
                let worktreeFiles = changes.files.filter { !$0.isStaged }

                changeGroup(title: "Staged Changes", files: stagedFiles, isExpanded: $isStagedExpanded, staged: true)
                changeGroup(title: "Changes", files: worktreeFiles, isExpanded: $isChangesExpanded, staged: false)
            }
            commitsSection
        }
        .onChange(of: workflow.repository.path) { _, _ in
            diffs = [:]
            expandedFileIDs = []
            loadingFileIDs = []
            expandedCommitIDs = []
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
            DockSectionHeader(title: title, count: files.count, isExpanded: isExpanded, style: style) {
                if staged {
                    DockIconButton(icon: .check, label: "Commit staged changes", isBusy: workflow.isMutatingSourceControl, size: 24, style: style) {
                        isCommitPopoverPresented = true
                    }
                    .disabled(actionsDisabled || files.isEmpty || workflow.changes?.conflictedCount ?? 0 > 0)
                    .popover(isPresented: $isCommitPopoverPresented, arrowEdge: .bottom) { commitPopover }
                }
                DockIconButton(icon: staged ? .minus : .plus, label: staged ? "Unstage all changes" : "Stage all changes", size: 24, style: style) {
                    perform(staged ? .unstage(files) : .stage(files))
                }
                .disabled(actionsDisabled || files.isEmpty)
            }
            if isExpanded.wrappedValue {
                if files.isEmpty {
                    Text(staged ? "No staged changes" : "No unstaged changes")
                        .dockFont(size: 12).foregroundStyle(Color.dockMetadataText)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in fileRow(file) }
                }
            }
        }
        .padding(.top, 8)
    }

    private var commitPopover: some View {
        let path = workflow.repository.path
        let message = Binding(get: { commitMessages[path, default: ""] }, set: { commitMessages[path] = $0 })
        let isEmpty = message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Text("Commit \(workflow.changes?.stagedCount ?? 0) staged to \(workflow.repository.branch)")
                .dockFont(size: 11).foregroundStyle(Color.dockMetadataText).lineLimit(1)
            TextField("Message", text: message, axis: .vertical)
                .textFieldStyle(.dockGlass)
                .dockFont(size: 12)
                .lineLimit(2...6)
                .accessibilityLabel("Commit message")
            Button {
                isCommitPopoverPresented = false
                perform(.commit(message.wrappedValue))
            } label: {
                DockActionLabel(title: "Commit", pendingTitle: "Committing…", isPending: workflow.isMutatingSourceControl)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dockPrimary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actionsDisabled || isEmpty)
        }
        .padding(12)
        .frame(width: 300)
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockSectionHeader(title: "Commits", count: workflow.commits.count, isExpanded: $isCommitsExpanded, style: style)
            if isCommitsExpanded {
                if let error = workflow.commitsError {
                    Text(error).dockFont(size: 12).foregroundStyle(Color.dockWarning).padding(8)
                } else if workflow.commits.isEmpty {
                    Text(workflow.isRefreshing ? "Loading commits…" : "No commits on this branch yet")
                        .dockFont(size: 12).foregroundStyle(Color.dockMetadataText).padding(8)
                }
                if let ahead = workflow.repository.aheadCount, let behind = workflow.repository.behindCount {
                    Text(ahead == 0 && behind == 0 ? "Up to date with upstream · last fetched state" : "\(ahead) ahead · \(behind) behind upstream · last fetched state")
                        .dockFont(size: 11).foregroundStyle(Color.dockMetadataText).padding(8)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(workflow.commits) { commit in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                if !expandedCommitIDs.insert(commit.id).inserted { expandedCommitIDs.remove(commit.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    DockIcon(.gitCommit, size: 14, color: .dockMetadataText)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(commit.subject).dockFont(size: 12).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                        Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))")
                                            .dockFont(size: 11).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Text(String(commit.id.prefix(7))).dockFont(size: 11, design: .monospaced).foregroundStyle(Color.dockMetadataText)
                                }
                                .padding(.vertical, 4)
                                .frame(minHeight: 36).contentShape(Rectangle())
                            }
                            .buttonStyle(.dockHover)
                            .help(commit.subject)
                            .accessibilityLabel("\(commit.subject), by \(commit.author). \(expandedCommitIDs.contains(commit.id) ? "Collapse" : "Expand") commit details")
                            if expandedCommitIDs.contains(commit.id) {
                                Text(commit.subject).dockFont(size: 12).textSelection(.enabled)
                                HStack {
                                    Text(commit.author)
                                    Text(commit.date, style: .date)
                                    Text(commit.date, style: .time)
                                    Spacer(minLength: 0)
                                    DockCopyButton(commit.id, label: "Copy commit hash", accessibilityLabel: "Copy commit hash")
                                }
                                .dockFont(size: 11).foregroundStyle(Color.dockMetadataText)
                                if !commit.references.isEmpty {
                                    Text(commit.references).dockFont(size: 11).foregroundStyle(Color.dockAccent).textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, expandedCommitIDs.contains(commit.id) ? 8 : 0)
                    }
                }
                if workflow.commits.count == 50 {
                    Text("Showing the latest 50 commits").dockFont(size: 11).foregroundStyle(Color.dockMetadataText).padding(8)
                }
            }
        }
        .padding(.top, 12)
    }

    private var pullRequestsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("PULL REQUESTS")
                    .dockFont(size: 10, weight: .bold, design: .monospaced)
                    .tracking(1.05)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 8)
                Text("\(workflow.githubPullRequests.count)")
                    .dockFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockAccent)
            }
            .frame(minHeight: 34)

            if workflow.githubPullRequests.isEmpty {
                Text("No open pull requests")
                    .dockFont(size: 11)
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ForEach(workflow.githubPullRequests.prefix(5)) { pullRequest in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(pullRequest.isDraft ? Color.dockMetadataText : Color.dockSuccessFill)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(pullRequest.number)  \(pullRequest.title)")
                                .dockFont(size: 11, weight: .medium)
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                            if let metadata = pullRequest.metadataLabel {
                                Text(metadata)
                                    .dockFont(size: 10, design: .monospaced)
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
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                }
            }
        }
        .padding(.top, 12)
    }

    private func sourceControlHeader(_ changes: RepositoryChangeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                DockIcon(.gitBranch)
                    .dockFont(size: 12, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                Text(changes.branch)
                    .dockFont(size: 12, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                DockIconButton(icon: .arrowsClockwise, label: "Refresh source control", isBusy: workflow.isRefreshing, style: style) {
                    Task { await onRefresh() }
                }
                .disabled(workflow.isMutatingSourceControl)
            }

            if let notice = workflow.sourceControlError ?? (changes.conflictedCount > 0 ? "Resolve conflicts, then stage the resolved files." : nil) {
                Text(notice)
                    .dockFont(size: 11)
                    .foregroundStyle(Color.dockWarning)
                    .lineLimit(2)
                    .help(notice)
            }

            if !isInspector { githubConnectionRow }
        }
            .padding(.bottom, 11)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    @ViewBuilder
    private var githubConnectionRow: some View {
        if workflow.isAuthenticatingGitHub || workflow.githubAuthenticationNotice?.hasPrefix("GitHub connected") == true {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    DockIcon(.checkCircle)
                        .dockFont(size: 11)
                        .foregroundStyle(Color.dockSuccess)
                    Text(workflow.githubAuthenticationNotice ?? "GitHub connected. Refreshing pull requests…")
                        .dockFont(size: 11)
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 8)
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.dockAccent)
                }
                if let code = workflow.githubAuthenticationCode {
                    Text(code)
                        .dockFont(size: 16, weight: .bold, design: .monospaced)
                        .tracking(2.2)
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                        .accessibilityLabel("GitHub device code \(code)")
                }
            }
            .padding(.vertical, 2)
        } else if workflow.isSigningOutGitHub {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.dockAccent)
                Text(workflow.githubAuthenticationNotice ?? "Signing out of GitHub…")
                    .dockFont(size: 11)
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
                        .dockFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.dockWarning)
                    Text("GitHub sign-in required.")
                        .dockFont(size: 11)
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 8)
                    Button("SIGN IN") {
                        workflow.authenticateGitHub()
                    }
                    .buttonStyle(.dockCompact)
                    .dockFont(size: 10, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockAccent)
                }
                .frame(minHeight: 24)
                if let notice = workflow.githubAuthenticationNotice {
                    Text(notice)
                        .dockFont(size: 10)
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let code = workflow.githubAuthenticationCode {
                    Text(code)
                        .dockFont(size: 16, weight: .bold, design: .monospaced)
                        .tracking(2.2)
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
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
                        .dockFont(size: 11)
                        .foregroundStyle(Color.dockSuccess)
                    Text("GitHub")
                        .dockFont(size: 10, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Color.dockMetadataText)
                    Link(github.id, destination: github.webURL)
                        .buttonStyle(.dockLink)
                        .lineLimit(1)
                    Spacer()
                    sourceControlIcon(workflow.isRefreshingGitHub ? .dotsThree : .arrowsClockwise, help: "Refresh GitHub") {
                        Task { await workflow.refreshGitHub() }
                    }
                    .disabled(workflow.isRefreshingGitHub)
                    .accessibilityIdentifier(WorkflowAccessibilityIdentifier.changesRefreshGitHub)
                    Button("SIGN OUT") {
                        workflow.signOutGitHub()
                    }
                    .buttonStyle(.dockCompact)
                    .dockFont(size: 9, weight: .semibold, design: .monospaced)
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
                .dockFont(size: 11, weight: .semibold)
                .foregroundStyle(Color.dockWarning)
            Text(message)
                .dockFont(size: 11)
                .foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Button(workflow.isAuthenticatingGitHub ? "Connecting…" : actionTitle, action: action)
                .buttonStyle(.dockCompact)
                .dockFont(size: 11, weight: .semibold)
                .foregroundStyle(Color.dockAccent)
                .disabled(workflow.isAuthenticatingGitHub)
        }
        .frame(minHeight: 24)
    }

    private func sourceControlIcon(_ systemName: Ph, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(systemName)
                .dockFont(size: 13, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(help)
    }

    private func fileRow(_ file: RepositoryFileChange) -> some View {
        let isExpanded = expandedFileIDs.contains(file.id)
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
                    DockIcon(file.isStaged ? .minus : .plus, size: 14, color: .dockSecondaryText)
                        .frame(width: 28, height: 30)
                }
                .buttonStyle(.dockPress)
                .help("\(file.isStaged ? "Unstage" : "Stage") \(file.path)")
                .accessibilityLabel("\(file.isStaged ? "Unstage" : "Stage") \(file.path)")
                .disabled(actionsDisabled)
                Text(statusLetter(for: file))
                    .dockFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(statusColor(for: file)).frame(width: 18)
                    .help(fileStatusDescription(for: file))
            }
            if onSelectFile == nil && isExpanded { diffCard(for: file) }
        }
    }

    @ViewBuilder
    private func diffCard(for file: RepositoryFileChange) -> some View {
        Group {
            if let diff = diffs[file.id] {
                let lines = Self.displayLines(diff.text)
                if lines.isEmpty {
                    diffNotice(file.status == .untracked || file.status == .added ? "Binary or empty file." : "No textual diff is available for this file.")
                } else {
                    SharedDiffView(patch: diff.text, path: file.path, contextLoader: file.status == .untracked ? nil : { lines in
                        try await RepositoryComparisonService.expandedPatch(path: projectPath ?? "", file: file.path,
                            arguments: file.isStaged ? ["diff", "--no-ext-diff", "--cached"] : ["diff", "--no-ext-diff"], original: diff.text, lines: lines, renameSource: file.renameSource)
                    }, projectPath: projectPath,
                        comparison: projectPath.map { DiffComparisonIdentity(repository: $0, revision: workflow.repository.headRevision ?? "unavailable", fingerprint: workflow.repositoryFingerprint ?? "") }, revisionNotes: revisionNotes)
                        .id(reviewScope + ":" + file.id)
                }
                if diff.isTruncated { diffNotice("Diff truncated for safe display.", color: .dockWarning) }
            } else if loadingFileIDs.contains(file.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…").dockFont(size: 11).foregroundStyle(Color.dockMetadataText)
                }
                .padding(10)
            } else {
                diffNotice("This file has no readable diff.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).dockSurfaceFill(Color.dockSurface2))
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func diffNotice(_ text: String, color: Color = .dockMetadataText) -> some View {
        Text(text)
            .dockFont(size: 11)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
                .dockFont(size: 12).foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if !fileDirectory(for: file).isEmpty {
                Text(fileDirectory(for: file))
                    .dockFont(size: 11).foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(showsSelection ? Color.dockAccent.opacity(0.13) : .clear, in: DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius))
        .contentShape(Rectangle())
    }

    private func perform(_ action: RepositorySourceControlAction) {
        let path = workflow.repository.path
        Task {
            let succeeded = await workflow.applySourceControl(action, path: path, refresh: onRefresh)
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
            DockIconLabel(title, icon: icon).dockFont(size: 12, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Text(detail).dockFont(size: 12).foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

    }
}
