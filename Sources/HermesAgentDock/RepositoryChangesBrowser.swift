import SwiftUI

/// Shared, popover-native source-control browser used by both global Changes
/// and the session inspector. The repository remains the source of truth; this
/// view only projects its current Git state and opens the inline editor.
struct RepositoryChangesBrowser: View {
    @ObservedObject var model: DockModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    let projectPath: String?
    let onRefresh: () async -> Void
    var onSelectProjectFolder: (() -> Void)?

    @State private var selectedDiff: RepositoryDiff?
    @State private var selectedFile: RepositoryFileChange?
    @State private var document: RepositoryFileDocument?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        if let changes = workflow.changes, workflow.repository.isGitRepository {
            if let document {
                RepositoryCodeWorkspaceView(
                    repositoryPath: workflow.repository.path,
                    document: document,
                    onClose: {
                        self.document = nil
                        selectedFile = nil
                        selectedDiff = nil
                    },
                    onSave: { draft in
                        guard await RepositoryService.saveDocument(path: workflow.repository.path, filePath: document.path, contents: draft) else { return false }
                        await onRefresh()
                        self.document = RepositoryFileDocument(path: document.path, contents: draft, byteCount: draft.lengthOfBytes(using: .utf8))
                        if let selectedFile { loadDiff(for: selectedFile) }
                        return true
                    }
                )
            } else {
                browser(changes)
            }
        } else if let projectPath {
            emptyState(
                icon: workflow.isRefreshing ? "arrow.triangle.2.circlepath" : "folder",
                title: workflow.isRefreshing ? "Inspecting project" : "Project is not a Git repository",
                detail: workflow.isRefreshing ? projectPath : "\(projectPath) is available as a local project folder, but it has no Git working tree to inspect."
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                emptyState(icon: "doc.text.magnifyingglass", title: "No project selected", detail: "Choose a project from Projects to inspect its local changes.")
                if let onSelectProjectFolder {
                    Button("SELECT PROJECT FOLDER", action: onSelectProjectFolder)
                        .buttonStyle(.scifiPress)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiAccent)
                }
            }
        }
    }

    private func browser(_ changes: RepositoryChangeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(error).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.scifiWarning)
            }

            sourceControlHeader(changes)

            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.scifiAccent)
                Text(changes.branch)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                sourceControlIcon("arrow.triangle.2.circlepath", help: "Refresh source control") {
                    Task { await onRefresh() }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.scifiMuted)
                Text("Changes")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.scifiFg)
                Spacer()
                Text("\(changes.changedFiles)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.scifiSurface8))
            }
            .padding(.top, 4)
            if changes.files.isEmpty {
                emptyState(icon: "checkmark.circle", title: "Working tree clean", detail: "No staged, unstaged, or untracked files were found.")
            } else {
                ForEach(changes.files) { file in fileRow(file) }
            }
        }
    }

    private func sourceControlHeader(_ changes: RepositoryChangeSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.scifiAccent)
            Text("SOURCE CONTROL")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Color.scifiFg)
            Spacer()
            Text("\(changes.stagedCount) staged")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiTertiary)
        }
        .padding(.bottom, 4)
    }

    private func sourceControlIcon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scifiMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.scifiPress)
        .help(help)
    }

    private func fileRow(_ file: RepositoryFileChange) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedDiff, selectedDiff.path == file.path, selectedDiff.isStaged == file.isStaged {
                    Text(selectedDiff.text.isEmpty ? "No textual diff is available for this file." : selectedDiff.text)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    if selectedDiff.isTruncated { Text("Diff truncated for safe display.").foregroundStyle(Color.scifiWarning) }
                } else {
                    Button(isLoading ? "Loading diff…" : "Load diff") { loadDiff(for: file) }.buttonStyle(.scifiPress).foregroundStyle(Color.scifiAccent).disabled(isLoading)
                }
                Button("Open code workspace") { openWorkspace(file) }.buttonStyle(.scifiPress).foregroundStyle(Color.scifiAccent).disabled(isLoading)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.status == .conflicted ? "exclamationmark.octagon" : "doc")
                    .foregroundStyle(statusColor(for: file))
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName(for: file)).lineLimit(1).foregroundStyle(Color.scifiFg)
                    if !fileDirectory(for: file).isEmpty {
                        Text(fileDirectory(for: file)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(1)
                    }
                }
                Spacer()
                Text(statusMark(for: file)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(statusColor(for: file))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private func fileName(for file: RepositoryFileChange) -> String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    private func fileDirectory(for file: RepositoryFileChange) -> String {
        file.path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func statusMark(for file: RepositoryFileChange) -> String {
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

    private func statusColor(for file: RepositoryFileChange) -> Color {
        if file.status == .conflicted { return .scifiDestructive }
        if file.isStaged { return .scifiAccent }
        if file.status == .untracked { return .scifiMuted }
        return .scifiWarning
    }

    private func loadDiff(for file: RepositoryFileChange) {
        Task { isLoading = true; selectedDiff = await RepositoryService.diff(path: workflow.repository.path, file: file); isLoading = false }
    }

    private func openWorkspace(_ file: RepositoryFileChange) {
        Task {
            isLoading = true; error = nil
            let resolvedDocument = await RepositoryService.loadDocument(path: workflow.repository.path, filePath: file.path)
            guard let resolvedDocument else { isLoading = false; error = "This file cannot be opened inline. Only regular UTF-8 files up to 256 KB are supported."; return }
            selectedFile = file; document = resolvedDocument; selectedDiff = nil; isLoading = false
        }
    }

    private func label(_ value: String) -> some View {
        Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.75).foregroundStyle(Color.scifiMuted)
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(color)
            Text(label).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Color.scifiTertiary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.scifiSurface4).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.scifiFg)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.scifiTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .scifiGlassPane()
    }
}
