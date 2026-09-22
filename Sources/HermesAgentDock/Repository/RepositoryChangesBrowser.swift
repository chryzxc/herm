import SwiftUI

/// Shared, popover-native source-control browser used by both global Changes
/// and the session inspector. The repository remains the source of truth; this
/// view only projects its current Git state and displays read-only diffs.
struct RepositoryChangesBrowser: View {
    @ObservedObject var model: DockModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    let projectPath: String?
    let onRefresh: () async -> Void
    var onSelectProjectFolder: (() -> Void)?
    var onSelectFile: ((RepositoryFileChange) -> Void)? = nil
    var selectedFilePath: String? = nil

    var isInspector = false

    @State private var selectedDiff: RepositoryDiff?

    @State private var isLoading = false
    @State private var error: String?
    @State private var isStagedExpanded = true
    @State private var isChangesExpanded = true

    var body: some View {
        if let changes = workflow.changes, workflow.repository.isGitRepository {
            browser(changes)
        } else if let projectPath {
            emptyState(
                icon: workflow.isRefreshing ? "refresh-cw" : "folder",
                title: workflow.isRefreshing ? "Inspecting project" : "Project is not a Git repository",
                detail: workflow.isRefreshing ? projectPath : "\(projectPath) is available as a local project folder, but it has no Git working tree to inspect."
            )
        } else {
            SessionProjectRequiredState(onSelectProject: onSelectProjectFolder)
        }
    }

    private func browser(_ changes: RepositoryChangeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.dockWarning)
                    .padding(.bottom, 8)
            }

            sourceControlHeader(changes)

            if !isInspector, case .available = workflow.githubIntegrationState {
                pullRequestsSection
            }

            if changes.files.isEmpty {
                emptyState(icon: "checkmark.circle", title: "Working tree clean", detail: "No staged, unstaged, or untracked files were found.")
            } else {
                let stagedFiles = changes.files.filter(\.isStaged)
                let worktreeFiles = changes.files.filter { !$0.isStaged }

                if !stagedFiles.isEmpty {
                    changeGroup(
                        title: "Staged",
                        files: stagedFiles,
                        isExpanded: $isStagedExpanded
                    )
                }

                if !worktreeFiles.isEmpty {
                    changeGroup(
                        title: "Changes",
                        files: worktreeFiles,
                        isExpanded: $isChangesExpanded
                    )
                }
            }
        }
    }

    private func changeGroup(
        title: String,
        files: [RepositoryFileChange],
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 7) {
                    LucideImage(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 8)
                    Text("\(files.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(title == "Staged" ? Color.dockAccent : Color.dockMetadataText)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isExpanded.wrappedValue ? "Collapse \(title.lowercased())" : "Expand \(title.lowercased())")

            if isExpanded.wrappedValue {
                ForEach(files) { file in fileRow(file) }
            }
        }
        .padding(.top, 12)
    }

    private var pullRequestsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("PULL REQUESTS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.05)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 8)
                Text("\(workflow.githubPullRequests.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockAccent)
            }
            .frame(minHeight: 34)

            if workflow.githubPullRequests.isEmpty {
                Text("No open pull requests")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ForEach(workflow.githubPullRequests.prefix(5)) { pullRequest in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(pullRequest.isDraft ? Color.dockMetadataText : Color.dockSuccess)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(pullRequest.number)  \(pullRequest.title)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                            if let metadata = pullRequest.metadataLabel {
                                Text(metadata)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.dockMetadataText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if let url = pullRequest.webURL {
                            Link("OPEN", destination: url)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                Text(changes.branch)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                sourceControlIcon("refresh-cw", help: "Refresh source control") {
                    Task { await onRefresh() }
                }
            }

            HStack(spacing: 7) {
                Text("\(changes.changedFiles) files")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                if changes.stagedCount > 0 {
                    Text("· \(changes.stagedCount) staged")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.dockAccent)
                }
                Spacer(minLength: 0)
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
                    LucideImage(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSuccess)
                    Text(workflow.githubAuthenticationNotice ?? "GitHub connected. Refreshing pull requests…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 8)
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.dockAccent)
                }
                if let code = workflow.githubAuthenticationCode {
                    Text(code)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .frame(minHeight: 24)
        } else {
        switch workflow.githubIntegrationState {
        case .noRemote:
            EmptyView()
        case .notLoaded:
            githubStatusRow(icon: "refresh-cw", message: "GitHub status not loaded.", actionTitle: "Refresh") {
                Task { await workflow.refreshGitHub() }
            }
        case .unavailable(let error):
            if case .unauthorized = error {
                HStack(spacing: 7) {
                    LucideImage(systemName: "person.badge.key")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockWarning)
                    Text("GitHub sign-in required.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 8)
                    Button("SIGN IN") {
                        workflow.authenticateGitHub()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockAccent)
                }
                .frame(minHeight: 24)
                if let notice = workflow.githubAuthenticationNotice {
                    Text(notice)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let code = workflow.githubAuthenticationCode {
                    Text(code)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                        .accessibilityLabel("GitHub device code \(code)")
                }
            } else {
                githubStatusRow(icon: "exclamationmark.triangle", message: githubStatusMessage(for: error), actionTitle: "Retry") {
                    Task { await workflow.refreshGitHub() }
                }
            }
        case .stale:
            githubStatusRow(icon: "exclamationmark.triangle", message: "Using last known GitHub data.", actionTitle: "Retry") {
                Task { await workflow.refreshGitHub() }
            }
        case .available:
            if let github = workflow.githubRepository {
                HStack(spacing: 7) {
                    LucideImage(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSuccess)
                    Text("GitHub")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Link(github.id, destination: github.webURL)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    sourceControlIcon(workflow.isRefreshingGitHub ? "ellipsis" : "refresh-cw", help: "Refresh GitHub") {
                        Task { await workflow.refreshGitHub() }
                    }
                    .disabled(workflow.isRefreshingGitHub)
                    .accessibilityIdentifier(WorkflowAccessibilityIdentifier.changesRefreshGitHub)
                    Button("SIGN OUT") {
                        workflow.signOutGitHub()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
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
        icon: String,
        message: String,
        actionTitle: String = "Connect GitHub",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            LucideImage(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockWarning)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Button(workflow.isAuthenticatingGitHub ? "Connecting…" : actionTitle, action: action)
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
                .disabled(workflow.isAuthenticatingGitHub)
        }
        .frame(minHeight: 24)
    }

    private func sourceControlIcon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideImage(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private func fileRow(_ file: RepositoryFileChange) -> some View {
        if let onSelectFile {
            Button {
                onSelectFile(file)
            } label: {
                fileRowLabel(file, showsSelection: selectedFilePath == file.id)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if let selectedDiff, selectedDiff.path == file.path, selectedDiff.isStaged == file.isStaged {
                        Text(selectedDiff.text.isEmpty ? "No textual diff is available for this file." : selectedDiff.text)
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        if selectedDiff.isTruncated { Text("Diff truncated for safe display.").foregroundStyle(Color.dockWarning) }
                    } else {
                        Button(isLoading ? "Loading diff…" : "Load diff") { loadDiff(for: file) }.buttonStyle(.borderless).foregroundStyle(Color.dockAccent).disabled(isLoading)
                    }

                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.leading, 26)
                .padding(.top, 4)
                .padding(.bottom, 10)
            } label: {
                fileRowLabel(file, showsSelection: false)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        }
    }

    private func fileRowLabel(_ file: RepositoryFileChange, showsSelection: Bool) -> some View {
        HStack(spacing: 8) {
            LucideImage(systemName: fileIcon(for: file))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusColor(for: file))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName(for: file))
                    .lineLimit(1)
                    .foregroundStyle(Color.dockPrimaryText)
                if !fileDirectory(for: file).isEmpty {
                    Text(fileDirectory(for: file))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Circle()
                .fill(statusColor(for: file))
                .frame(width: 7, height: 7)
                .help(fileStatusDescription(for: file))
                .accessibilityLabel(fileStatusDescription(for: file))
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, showsSelection ? 8 : 0)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background {
            if showsSelection {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.dockAccent.opacity(0.13))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    private func fileName(for file: RepositoryFileChange) -> String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    private func fileDirectory(for file: RepositoryFileChange) -> String {
        file.path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func fileIcon(for file: RepositoryFileChange) -> String {
        switch file.path.split(separator: ".").last?.lowercased() {
        case "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs": "doc.text"
        case "json", "yaml", "yml", "toml": "doc.text"
        case "md", "txt": "doc.plaintext"
        default: "doc"
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
        if file.status == .untracked { return .dockSecondaryText }
        return .dockWarning
    }

    private func loadDiff(for file: RepositoryFileChange) {
        Task { isLoading = true; selectedDiff = await RepositoryService.diff(path: workflow.repository.path, file: file); isLoading = false }
    }


    private func label(_ value: String) -> some View {
        Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.75).foregroundStyle(Color.dockSecondaryText)
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
            Text(label.lowercased().capitalized).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dockMetadataText)
        }.frame(maxWidth: .infinity, alignment: .leading).dockCard(padding: 10)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LucideLabel(title, icon: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

    }
}
