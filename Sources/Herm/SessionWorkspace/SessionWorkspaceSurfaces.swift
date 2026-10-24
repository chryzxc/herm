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
        .dockPaneTint(Color.dockSurface2.opacity(0.55))
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
                    .padding(.horizontal, 18)
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
        .padding(.horizontal, 14)
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
                            .padding(.horizontal, 18)
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
        .dockPaneTint(Color.dockSurface2.opacity(0.55))
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
        .padding(.horizontal, 14)
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
        .padding(.horizontal, 14)
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
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            if diff.isTruncated {
                Text("Diff truncated for safe display.")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, 14)
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

/// The session's folder and branch, under the chat composer. Choosing another
/// worktree changes what Explorer and Source Control show; the agent keeps
/// working in its own folder.
struct WorktreePicker: View {
    /// Empty when the folder is not a Git repository.
    let worktrees: [RepositoryWorktreeSummary]
    /// The session's bound source folder.
    let mainPath: String?
    @Binding var selection: String?
    @State private var isOpen = false
    @State private var query = ""

    private var current: RepositoryWorktreeSummary? { worktrees.first { $0.path == selection } }

    private var filtered: [RepositoryWorktreeSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return worktrees }
        return worktrees.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) || ($0.branch ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder
    var body: some View {
        if worktrees.count > 1 {
            Button {
                isOpen.toggle()
            } label: {
                label
            }
            .buttonStyle(.dockHover)
            .help("Choose the worktree Explorer and Source Control show")
            .popover(isPresented: $isOpen, arrowEdge: .top) { list }
        } else {
            label.help(current?.path ?? selection ?? "")
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            DockIcon(.folder).foregroundStyle(Color.dockMetadataText)
            Text(current?.displayName ?? selection.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Project")
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1).truncationMode(.middle)
            if current != nil {
                DockIcon(.gitBranch).foregroundStyle(Color.dockMetadataText).padding(.leading, 4)
                Text(branchLabel(current))
                    .dockFont(.metadata, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            if worktrees.count > 1 {
                DockIcon(.caretUpDown).dockFont(.compactStatus, weight: .regular).foregroundStyle(
                    Color.dockMetadataText)
            }
            Spacer(minLength: 0)
        }
        .dockFont(.metadata)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if worktrees.count > 6 {
                DockTextField("Search worktrees", text: $query).textFieldStyle(.dockGlass).padding(8)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { tree in row(tree) }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320)
    }

    private func branchLabel(_ tree: RepositoryWorktreeSummary?) -> String {
        guard let tree else { return "" }
        return tree.branch ?? tree.headRevision.map { "detached @ \($0)" } ?? "detached"
    }

    private func row(_ tree: RepositoryWorktreeSummary) -> some View {
        Button {
            selection = tree.path
            isOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(
                    systemName: tree.path == selection
                        ? "checkmark" : (tree.isLocked ? "lock" : "arrow.triangle.branch")
                )
                .frame(width: 14).foregroundStyle(tree.path == selection ? Color.dockAccent : Color.dockMetadataText)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(tree.displayName).dockFont(.body).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                            .truncationMode(.middle)
                        if tree.path == mainPath {
                            Text("source folder").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    Text(branchLabel(tree)).dockFont(.machineMetadata).foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if (tree.snapshot?.changedFiles ?? 0) > 0 { Circle().fill(Color.dockAccent).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tree.path)
        .disabled(tree.isPrunable)
        .opacity(tree.isPrunable ? 0.45 : 1)
    }
}
