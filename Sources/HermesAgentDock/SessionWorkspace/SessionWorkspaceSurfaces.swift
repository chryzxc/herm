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
            ScrollView {
                SessionFilesView(
                    projectPath: scope?.repositoryPath,
                    onRefresh: onRefresh,
                    scope: scope,
                    isCompact: isCompact,
                    onOpenFile: onOpenFile
                )
                .padding(.vertical, isCompact ? 4 : 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
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
                    selectedFilePath: selectedFilePath
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
        .background(Color.dockSurface2.opacity(0.55))
        .task(id: repositoryPath) {
            guard let repositoryPath, !repositoryPath.isEmpty else { return }
            await center.refreshScoped(repositoryPath: repositoryPath)
        }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
    }

    private var pullRequestList: some View {
        VStack(spacing: 0) {
            filterBar
            if let error = center.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if center.isInitialLoad {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Loading pull requests…")
                                .font(.system(size: 12))
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
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(PullRequestFilter.allCases) { filter in
                    RepositoryFilterTabButton(title: filter.rawValue, isSelected: center.filter == filter) {
                        center.filter = filter
                    }
                }
            }
            Divider().frame(height: 22)
            HStack(spacing: 8) {
                LucideIcon(name: .search, size: 16)
                TextField("Search pull requests", text: $center.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.dockCanvas.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let repositoryPath {
                Button {
                    Task { await center.refreshScoped(repositoryPath: repositoryPath) }
                } label: {
                    LucideIcon(name: .refreshCw, size: 15, color: Color.dockSecondaryText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(DockPressButtonStyle())
                .disabled(center.isRefreshing)
                .help("Refresh pull requests")
                .accessibilityLabel("Refresh pull requests")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.dockSurface2.opacity(0.45))
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
                LucideImage(systemName: "folder.badge.questionmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No project selected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Choose a project from Projects to use this session’s workspace.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            if let onSelectProject {
                Button("SELECT PROJECT FOLDER", action: onSelectProject)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockAccent)
            }
            Divider().overlay(Color.dockBorderLight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 32)
        .padding(.top, 48)
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
                icon: "doc.text.magnifyingglass",
                title: "No file selected",
                detail: "Select a changed file to preview its diff here."
            )
        }
    }

    private func header(_ file: RepositoryFileChange) -> some View {
        HStack(spacing: 10) {
            LucideImage(systemName: "doc.text")
                .foregroundStyle(Color.dockAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(file.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(statusLabel(for: file).uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else if let diff {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(PullRequestDiffPresentation.lines(diff.text)) { line in
                        PullRequestDiffLineView(line: line)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            if diff.text.isEmpty {
                Text("No textual diff is available for this file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            if diff.isTruncated {
                Text("Diff truncated for safe display.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        } else {
            Text("This file has no readable diff.")
                .font(.system(size: 12))
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
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            LucideImage(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockSecondaryText)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dockCanvas)
    }
}
