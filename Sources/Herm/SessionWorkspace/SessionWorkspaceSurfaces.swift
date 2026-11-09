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
            .id(scope?.identity)
            .dockPadding(.horizontal, 6)
            .dockPadding(.vertical, isCompact ? 4 : 8)
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
                .dockPadding(16)
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
                    .dockPadding(.horizontal, DockSpacing.section)
                    .dockPadding(.vertical, DockSpacing.control)
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
                        .dockPadding(.vertical, 32)
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
                .dockPadding(.horizontal, 10)
                .dockPadding(.vertical, 6)
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
        .dockPadding(.horizontal, DockSpacing.section)
        .dockPadding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private var searchField: some View {
        DockSearchField(placeholder: "Search pull requests", text: $center.query)
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
                            .dockPadding(.horizontal, DockSpacing.section)
                            .dockPadding(.vertical, DockSpacing.control)
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
                                .dockPadding(.vertical, 32)
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
                        .dockPadding(.horizontal, 10)
                        .dockPadding(.vertical, 6)
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
            DockSearchField(placeholder: "Search issues", text: $center.query)
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
        .dockPadding(.horizontal, DockSpacing.section)
        .dockPadding(.vertical, 10)
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
        .dockPadding(.horizontal, 4)
        .dockPadding(.top, 20)
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
        .dockPadding(.horizontal, DockSpacing.section)
        .dockPadding(.vertical, 10)
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
            .dockPadding(14)
        } else if let diff {
            SharedDiffView(patch: diff.text, path: diff.path)
            if diff.text.isEmpty {
                Text("No textual diff is available for this file.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .dockPadding(.horizontal, DockSpacing.section)
                    .dockPadding(.top, 8)
            }
            if diff.isTruncated {
                Text("Diff truncated for safe display.")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .dockPadding(.horizontal, DockSpacing.section)
                    .dockPadding(.vertical, 8)
            }
        } else {
            Text("This file has no readable diff.")
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .dockPadding(14)
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

/// The composer shows the session workspace and opens other worktrees in new chats.
struct WorktreePicker: View {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    let worktrees: [RepositoryWorktreeSummary]
    let selection: String?
    var worktreesUnavailable = false
    var onOpenWorktree: ((String) async -> Void)? = nil
    var newTask: (() async -> Void)? = nil
    @State private var isOpen = false
    @State private var isConfirmingNewTask = false
    @State private var isCreatingTask = false

    private var current: RepositoryWorktreeSummary? { worktrees.first { $0.path == selection } }
    private var canStartTask: Bool { newTask != nil && current?.headRevision != nil }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                DockIcon(.folder).foregroundStyle(Color.dockMetadataText)
                Text(current?.displayName ?? selection.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Project")
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            .dockFont(.metadata)
            .dockPadding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .help(current?.path ?? selection ?? "")
            Spacer(minLength: 0)
            if worktrees.count > 1 || canStartTask || worktreesUnavailable {
                Button {
                    isOpen.toggle()
                } label: {
                    branch
                }
                .buttonStyle(.dockHover)
                .disabled(isCreatingTask)
                .help("Worktrees")
                .accessibilityLabel("Choose a worktree")
                .dockPopover(isPresented: $isOpen, attachmentAnchor: .point(.topTrailing), arrowEdge: .bottom) {
                    WorktreeChooserPanel(
                        worktrees: worktrees, selection: selection, unavailable: worktreesUnavailable,
                        canStartTask: canStartTask,
                        onSelect: { path in
                            guard let onOpenWorktree else { return }
                            isOpen = false
                            isCreatingTask = true
                            Task {
                                await onOpenWorktree(path)
                                isCreatingTask = false
                            }
                        },
                        onCreate: {
                            isOpen = false
                            DispatchQueue.main.async { isConfirmingNewTask = true }
                        }
                    )
                }
            } else if current != nil {
                branch
            }
        }
        .dockPadding(.horizontal, 8)
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
            Text("Creates a new branch from \(WorktreeChooserPanel.branchLabel(current)) at ")
                + (current?.headRevision.map { DockCommitPresentation.text($0, length: nil, scale: workspaceScale) }
                    ?? Text("HEAD"))
                + Text(" in its own folder. Your draft moves to a new chat there; this chat keeps its folder.")
        }
    }

    private var branch: some View {
        HStack(spacing: 6) {
            if current != nil {
                DockIcon(.gitBranch).foregroundStyle(Color.dockMetadataText)
                Text(WorktreeChooserPanel.branchLabel(current))
                    .dockFont(.metadata, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            if isCreatingTask {
                DockActivityIndicator(state: .running, size: 10)
            } else if worktrees.count > 1 || canStartTask || worktreesUnavailable {
                DockIcon(.caretUpDown).dockFont(.compactStatus, weight: .regular).foregroundStyle(
                    Color.dockMetadataText)
            }
        }
        .dockFont(.metadata)
        .dockPadding(.horizontal, 4)
        .frame(height: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A stable popover size keeps the chooser attached to the composer as its list changes.
struct WorktreeChooserPanel: View {
    let worktrees: [RepositoryWorktreeSummary]
    let selection: String?
    let unavailable: Bool
    let canStartTask: Bool
    let onSelect: (String) -> Void
    let onCreate: () -> Void
    @State private var query = ""

    private var current: RepositoryWorktreeSummary? { worktrees.first { $0.path == selection } }
    private var others: [RepositoryWorktreeSummary] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return worktrees.filter { tree in
            tree.path != selection
                && (search.isEmpty || tree.displayName.localizedCaseInsensitiveContains(search)
                    || (tree.branch ?? "").localizedCaseInsensitiveContains(search)
                    || tree.path.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Worktrees").dockFont(.rowTitle, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                Text("Choose a worktree to start a new chat.")
                    .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            }
            .dockPadding(.horizontal, 14)
            .dockPadding(.top, 12)
            .dockPadding(.bottom, 10)

            if let current {
                HStack(alignment: .center, spacing: 8) {
                    DockIcon(.check, size: 12, color: .dockSecondaryText).frame(width: 16)
                    worktreeDetails(current)
                    Spacer(minLength: 8)
                    Text("Current").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                }
                .dockPadding(.horizontal, 14)
                .dockPadding(.vertical, 8)
                .help(current.path)
                .accessibilityElement(children: .combine)
            }

            if worktrees.count > 6 {
                HStack(spacing: 6) {
                    DockIcon(.magnifyingGlass, size: 12, color: .dockMetadataText)
                    DockTextField("Search worktrees", text: $query)
                        .textFieldStyle(.plain)
                }
                .dockPadding(.horizontal, 8)
                .frame(height: 28)
                .dockWell(.sunken)
                .dockPadding(.horizontal, 12)
                .dockPadding(.top, 6)
                .dockPadding(.bottom, 8)
            }

            Color.dockBorderLight.frame(height: DockLayout.hairline)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if unavailable {
                        message("Worktrees unavailable. Refresh to try again.")
                    } else if others.isEmpty {
                        message(query.isEmpty ? "No other worktrees" : "No matching worktrees")
                    } else {
                        ForEach(others) { tree in
                            Button {
                                onSelect(tree.path)
                            } label: {
                                row(tree)
                            }
                            .buttonStyle(.dockHover)
                            .disabled(tree.isPrunable)
                            .help(tree.path)
                        }
                    }
                }
                .dockPadding(.horizontal, 6)
                .dockPadding(.vertical, 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if canStartTask {
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                HStack {
                    Button {
                        onCreate()
                    } label: {
                        SwiftUI.Label("New worktree task", icon: .plus)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.dockSecondary)
                    .help("Create a worktree and start a new chat")
                }
                .dockButtonSize(.standard)
                .dockPadding(.horizontal, 12)
                .dockPadding(.vertical, 10)
            }
        }
        .frame(width: 340, height: 440)
    }

    private func message(_ text: String) -> some View {
        Text(text).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            .dockPadding(.horizontal, 8).dockPadding(.vertical, 10)
    }

    private func worktreeDetails(_ tree: RepositoryWorktreeSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tree.displayName).dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText).lineLimit(1).truncationMode(.middle)
            Text(Self.branchLabel(tree)).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ tree: RepositoryWorktreeSummary) -> some View {
        let changed = tree.snapshot?.changedFiles ?? 0
        let status =
            tree.isPrunable || tree.snapshot == nil || tree.snapshot?.isStale == true
            ? "Unavailable" : (changed > 0 ? "\(changed) changed" : "")
        return HStack(spacing: 8) {
            DockIcon(tree.isLocked ? .lock : .gitBranch, size: 12, color: .dockMetadataText).frame(width: 16)
            worktreeDetails(tree)
            if !status.isEmpty {
                Text(status).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
            }
            if !tree.isPrunable { DockIcon(.caretRight, size: 10, color: .dockMetadataText) }
        }
        .dockPadding(.horizontal, 8)
        .dockPadding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tree.displayName), \(Self.branchLabel(tree))\(status.isEmpty ? "" : ", " + status)")
    }

    static func branchLabel(_ tree: RepositoryWorktreeSummary?) -> String {
        guard let tree else { return "" }
        return tree.branch ?? tree.headRevision.map { "Detached · \($0)" } ?? "Detached"
    }
}
