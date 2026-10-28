import SwiftUI

struct SessionExplorerSurface: View {
    let scope: SessionRepositoryScope?
    var isCompact = false
    let onRefresh: () async -> Void
    let onOpenFile: (SessionRepositoryScope, RepositoryFileDocument) -> Void

    var body: some View {
        if scope == nil {
            SessionProjectRequiredState()
        } else {
            SessionFilesView(
                projectPath: scope?.repositoryPath,
                onRefresh: onRefresh,
                scope: scope,
                isCompact: isCompact,
                onOpenFile: onOpenFile
            )
            .padding(.horizontal, 6)
            .padding(.vertical, isCompact ? 4 : 8)
            .background(Color.dockCanvas)
        }
    }
}

struct SessionSourceControlSurface: View {
    @ObservedObject var model: DockModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    let scope: SessionRepositoryScope?
    let onRefresh: () async -> Void
    let onSelectFile: (RepositoryFileChange) -> Void
    let selectedFilePath: String?

    var body: some View {
        if scope == nil {
            SessionProjectRequiredState()
        } else {
            ScrollView {
                RepositoryChangesBrowser(
                    model: model,
                    workflow: workflow,
                    projectPath: scope?.repositoryPath,
                    onRefresh: onRefresh,
                    onSelectFile: onSelectFile,
                    selectedFilePath: selectedFilePath,
                    showsBranch: false
                )
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color.dockCanvas)
        }
    }
}

struct SessionPullRequestsSurface: View {
    @ObservedObject var center: PullRequestCenterModel
    let repositoryPath: String?
    let onOpenChat: (PullRequestRecord) -> Void

    var body: some View {
        Group {
            if repositoryPath == nil {
                SessionProjectRequiredState()
            } else {
                pullRequestList
            }
        }
        .background(Color.dockCanvas)
        .task(id: repositoryPath) {
            guard let repositoryPath, !repositoryPath.isEmpty else { return }
            await center.refreshScoped(repositoryPath: repositoryPath)
        }
        .onDisappear { center.cancelLoads() }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
    }

    private var pullRequestList: some View {
        VStack(spacing: 0) {
            filterBar
            if let error = center.errorMessage {
                Text(error)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, DockSpacing.section)
                    .padding(.vertical, DockSpacing.control)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if center.isInitialLoad {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Loading pull requests…")
                                .dockFont(.body)
                                .foregroundStyle(Color.dockMetadataText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(center.visible) { pullRequest in
                            Button {
                                center.selectedID = pullRequest.id
                            } label: {
                                PullRequestRowView(
                                    pullRequest: pullRequest,
                                    isSelected: center.selectedID == pullRequest.id
                                )
                            }
                            .buttonStyle(.dockHover)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: DockSpacing.control) {
            searchField
            HStack(spacing: DockSpacing.control) {
                PullRequestFilterPicker(selection: $center.filter)
                Spacer(minLength: DockSpacing.control)
                refreshButton
            }
        }
        .dockFont(.body)
        .padding(.horizontal, DockSpacing.section)
        .padding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            DockIcon(.magnifyingGlass, size: 15, color: Color.dockMetadataText)
            TextField(
                "", text: $center.query, prompt: Text("Search pull requests").foregroundColor(Color.dockMetadataText)
            )
            .textFieldStyle(.plain)
            .accessibilityLabel("Search pull requests")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(Color.dockControlSurface))
        .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius))
    }

    @ViewBuilder private var refreshButton: some View {
        if let repositoryPath {
            DockIconButton(
                icon: .arrowsClockwise, label: "Refresh pull requests", isBusy: center.isRefreshing,
                style: DockThemePalette(theme: DockThemeRuntime.current)
            ) {
                Task { await center.refreshScoped(repositoryPath: repositoryPath) }
            }
        }
    }

}

struct SessionIssuesSurface: View {
    @ObservedObject var center: IssueCenterModel
    let repositoryPath: String?

    var body: some View {
        Group {
            if repositoryPath == nil {
                SessionProjectRequiredState()
            } else {
                VStack(spacing: 0) {
                    filterBar
                    if let error = center.errorMessage {
                        Text(error)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockWarning)
                            .padding(.horizontal, DockSpacing.section)
                            .padding(.vertical, DockSpacing.control)
                    }
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if center.isRefreshing && center.records.isEmpty {
                                VStack(spacing: 12) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading issues…")
                                        .dockFont(.body)
                                        .foregroundStyle(Color.dockMetadataText)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                            } else {
                                ForEach(center.visible) { issue in
                                    Button {
                                        center.selectedIssueID = issue.id
                                    } label: {
                                        IssueRowView(
                                            issue: issue, isSelected: center.selectedIssueID == issue.id,
                                            viewer: center.viewerLogin)
                                    }
                                    .buttonStyle(.dockHover)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .background(Color.dockCanvas)
        .task(id: repositoryPath) {
            guard let repositoryPath, !repositoryPath.isEmpty else { return }
            await center.refreshScoped(repositoryPath: repositoryPath)
        }
        .onDisappear { center.cancelLoads() }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
    }

    private var filterBar: some View {
        VStack(spacing: DockSpacing.control) {
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 15, color: Color.dockMetadataText)
                TextField(
                    "", text: $center.query, prompt: Text("Search issues").foregroundColor(Color.dockMetadataText)
                )
                .textFieldStyle(.plain)
                .accessibilityLabel("Search issues")
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                DockThemeShape(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(Color.dockControlSurface)
            )
            .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius))
            HStack(spacing: DockSpacing.control) {
                DockTabBar(options: GitHubIssueFilter.allCases, selection: $center.filter, title: { $0.rawValue })
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: DockSpacing.control)
                if let repositoryPath {
                    DockIconButton(
                        icon: .arrowsClockwise, label: "Refresh issues", isBusy: center.isRefreshing,
                        style: DockThemePalette(theme: DockThemeRuntime.current)
                    ) {
                        Task { await center.refreshScoped(repositoryPath: repositoryPath) }
                    }
                }
            }
        }
        .dockFont(.body)
        .padding(.horizontal, DockSpacing.section)
        .padding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }
}

/// The shared disconnected state for every session workspace surface. A
/// session can exist without a project, so Files, Changes, and Pull Requests
/// must explain that condition in exactly the same way.
struct SessionProjectRequiredState: View {
    var onSelectProject: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                DockIcon(.folderDashed)
                    .dockFont(.pageTitle, weight: .medium)
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No project selected")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Choose a project from Projects to use this session’s workspace.")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            if let onSelectProject {
                Button("Choose project folder", action: onSelectProject)
                    .buttonStyle(.dockCompact)
                    .dockFont(.body, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4)
        .padding(.top, 20)
        .background(Color.dockCanvas)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No project selected. Choose a project from Projects to use this session workspace.")
    }
}

struct SessionChangeDiffPreview: View {
    let file: RepositoryFileChange?
    let diff: RepositoryDiff?
    let isLoading: Bool

    var body: some View {
        if let file {
            VStack(alignment: .leading, spacing: 0) {
                header(file)
                Divider().overlay(Color.dockBorderLight)
                content(file)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.dockCanvas)
        } else {
            SessionSurfacePreviewPlaceholder(
                icon: .fileMagnifyingGlass,
                title: "No file selected",
                detail: "Select a changed file to preview its diff here."
            )
        }
    }

    private func header(_ file: RepositoryFileChange) -> some View {
        HStack(spacing: 10) {
            DockIcon(.fileText)
                .foregroundStyle(Color.dockAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(file.path)
                    .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(statusLabel(for: file).uppercased())
                .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                .foregroundStyle(Color.dockWarning)
        }
        .padding(.horizontal, DockSpacing.section)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(_ file: RepositoryFileChange) -> some View {
        if isLoading && diff == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading diff…")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else if let diff {
            SharedDiffView(patch: diff.text, path: diff.path)
            if diff.text.isEmpty {
                Text("No textual diff is available for this file.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, DockSpacing.section)
                    .padding(.top, 8)
            }
            if diff.isTruncated {
                Text("Diff truncated for safe display.")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, DockSpacing.section)
                    .padding(.vertical, 8)
            }
        } else {
            Text("This file has no readable diff.")
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .padding(14)
        }
    }

    private func statusLabel(for file: RepositoryFileChange) -> String {
        switch file.status {
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        case .modified: "Modified"
        case .unknown: "Unknown"
        }
    }
}

struct SessionSurfacePreviewPlaceholder: View {
    let icon: Ph
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            DockIcon(icon)
                .dockFont(.metric, weight: .medium)
                .foregroundStyle(Color.dockMetadataText)
            Text(title)
                .dockFont(.navigation, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
            Text(detail)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dockCanvas)
    }
}

/// The session's folder and branch, at the trailing end of the strip under the
/// chat composer. Choosing another worktree changes what Explorer and Source
/// Control show; the agent keeps working in its own folder. `newTask` branches
/// the shown worktree into a fresh one and moves the draft to a new chat there.
struct WorktreePicker: View {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    /// Empty when the folder is not a Git repository.
    let worktrees: [RepositoryWorktreeSummary]
    /// The session's bound source folder.
    let mainPath: String?
    @Binding var selection: String?
    /// Nil when a task worktree cannot be created here.
    var newTask: (() async -> Void)? = nil
    @State private var query = ""
    @State private var isConfirmingNewTask = false
    @State private var isCreatingTask = false

    private var current: RepositoryWorktreeSummary? { worktrees.first { $0.path == selection } }

    /// A worktree needs a committed HEAD to branch from.
    private var canStartTask: Bool { newTask != nil && current?.headRevision != nil }

    private var filtered: [RepositoryWorktreeSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return worktrees }
        return worktrees.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) || ($0.branch ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            folder.help(current?.path ?? selection ?? "")
            Spacer(minLength: 0)
            if worktrees.count > 1 || canStartTask {
                DockMenu {
                    menu
                } label: {
                    branch
                }
                .disabled(isCreatingTask)
                .help("Choose the worktree Explorer and Source Control show")
            } else if current != nil {
                branch
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .confirmationDialog("Start a task in a new worktree?", isPresented: $isConfirmingNewTask) {
            Button("Create Worktree") {
                guard let newTask else { return }
                isCreatingTask = true
                Task {
                    await newTask()
                    isCreatingTask = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new branch from \(branchLabel(current)) at ")
                + (current?.headRevision.map { DockCommitPresentation.text($0, length: nil, scale: workspaceScale) }
                    ?? Text("HEAD"))
                + Text(" in its own folder. Your draft moves to a new chat there; this chat keeps its folder.")
        }
    }

    private var folder: some View {
        HStack(spacing: 6) {
            DockIcon(.folder).foregroundStyle(Color.dockMetadataText)
            Text(current?.displayName ?? selection.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Project")
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1).truncationMode(.middle)
        }
        .dockFont(.metadata)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var branch: some View {
        HStack(spacing: 6) {
            if current != nil {
                DockIcon(.gitBranch).foregroundStyle(Color.dockMetadataText)
                Text(branchLabel(current))
                    .dockFont(.metadata, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            if isCreatingTask {
                DockActivityIndicator(state: .running, size: 10)
            } else if worktrees.count > 1 || canStartTask {
                DockIcon(.caretUpDown).dockFont(.compactStatus, weight: .regular).foregroundStyle(
                    Color.dockMetadataText)
            }
        }
        .dockFont(.metadata)
        .padding(.horizontal, 4)
        .frame(height: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var menu: some View {
        if worktrees.count > 6 {
            DockTextField("Search worktrees", text: $query).textFieldStyle(.dockGlass).padding(.bottom, 4)
        }
        DockMenuSection("Worktrees") {
            ForEach(filtered) { tree in
                Button {
                    selection = tree.path
                } label: {
                    row(tree)
                }
                .disabled(tree.isPrunable)
                .help(tree.path)
            }
        }
        if canStartTask {
            Divider().padding(.vertical, 4)
            Button {
                isConfirmingNewTask = true
            } label: {
                SwiftUI.Label("New task in worktree…", icon: .plus)
            }
        }
    }

    private func branchLabel(_ tree: RepositoryWorktreeSummary?) -> String {
        guard let tree else { return "" }
        return tree.branch ?? tree.headRevision.map { "detached @ \($0)" } ?? "detached"
    }

    private func row(_ tree: RepositoryWorktreeSummary) -> some View {
        let isSelected = tree.path == selection
        let changed = tree.snapshot?.changedFiles ?? 0
        return HStack(spacing: 8) {
            DockIcon(
                isSelected ? .check : (tree.isLocked ? .lock : .gitBranch), size: 12,
                color: isSelected ? Color.dockPrimaryText : Color.dockMetadataText
            )
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tree.displayName).lineLimit(1).truncationMode(.middle)
                    if tree.path == mainPath {
                        Text("source").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    }
                }
                Text(branchLabel(tree)).dockFont(.machineMetadata).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 16)
            if changed > 0 {
                Text("\(changed) changed").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 260)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(tree.displayName), \(branchLabel(tree))\(isSelected ? ", selected" : "")\(changed > 0 ? ", \(changed) changed" : "")"
        )
    }
}
