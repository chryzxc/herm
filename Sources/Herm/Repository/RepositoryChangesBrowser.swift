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

    @State private var diffs: [String: RepositoryDiff] = [:]
    @State private var expandedFileIDs: Set<String> = []
    @State private var loadingFileIDs: Set<String> = []
    @State private var error: String?
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
                emptyState(icon: .checkCircle, title: "Working tree clean", detail: "No staged, unstaged, or untracked files were found.")
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
        .onChange(of: changes) { _, newChanges in
            // Cached diffs go stale with the working tree; refetch the open ones.
            let liveIDs = Set(newChanges.files.map(\.id))
            diffs = [:]
            expandedFileIDs.formIntersection(liveIDs)
            for file in newChanges.files where expandedFileIDs.contains(file.id) { loadDiff(for: file) }
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
                    DockIcon(isExpanded.wrappedValue ? .caretDown : .caretRight)
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
            .buttonStyle(.dockHover)
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
                DockIcon(.gitBranch)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Text(changes.branch)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                sourceControlIcon(.arrowsClockwise, help: "Refresh source control") {
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
                    DockIcon(.checkCircle)
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
            githubStatusRow(icon: .arrowsClockwise, message: "GitHub status not loaded.", actionTitle: "Refresh") {
                Task { await workflow.refreshGitHub() }
            }
        case .unavailable(let error):
            if case .unauthorized = error {
                HStack(spacing: 7) {
                    DockIcon(.userGear)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockWarning)
                    Text("GitHub sign-in required.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 8)
                    Button("SIGN IN") {
                        workflow.authenticateGitHub()
                    }
                    .buttonStyle(.dockHover)
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
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSuccess)
                    Text("GitHub")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Link(github.id, destination: github.webURL)
                        .font(.system(size: 11, weight: .medium))
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
                    .buttonStyle(.dockHover)
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
        icon: Ph,
        message: String,
        actionTitle: String = "Connect GitHub",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            DockIcon(icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockWarning)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Button(workflow.isAuthenticatingGitHub ? "Connecting…" : actionTitle, action: action)
                .buttonStyle(.dockHover)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
                .disabled(workflow.isAuthenticatingGitHub)
        }
        .frame(minHeight: 24)
    }

    private func sourceControlIcon(_ systemName: Ph, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
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
            .buttonStyle(.dockHover)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        } else {
            let isExpanded = expandedFileIDs.contains(file.id)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    toggle(file)
                } label: {
                    HStack(spacing: 6) {
                        DockIcon(isExpanded ? .caretDown : .caretRight)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.dockMetadataText)
                            .frame(width: 12)
                        fileRowLabel(file, showsSelection: false)
                    }
                }
                .buttonStyle(.dockHover)
                .help(isExpanded ? "Hide diff" : "Show diff")

                if isExpanded { diffCard(for: file) }
            }
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
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
                    let diffLines = LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in PullRequestDiffLineView(line: line) }
                    }
                    // Short diffs hug their content; long ones scroll inside the card.
                    ViewThatFits(in: .vertical) {
                        diffLines
                        ScrollView { diffLines }
                    }
                    .frame(maxHeight: Self.maxDiffHeight)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                }
                if diff.isTruncated { diffNotice("Diff truncated for safe display.", color: .dockWarning) }
            } else if loadingFileIDs.contains(file.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                }
                .padding(10)
            } else {
                diffNotice("This file has no readable diff.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dockSurface2)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func diffNotice(_ text: String, color: Color = .dockMetadataText) -> some View {
        Text(text)
            .font(.system(size: 11))
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
        HStack(spacing: 8) {
            Text(statusLetter(for: file))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor(for: file))
                .frame(width: 18, height: 18)
                .background(statusColor(for: file).opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help(fileStatusDescription(for: file))
                .accessibilityLabel(fileStatusDescription(for: file))
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName(for: file))
                    .lineLimit(1)
                    .foregroundStyle(Color.dockPrimaryText)
                if !fileDirectory(for: file).isEmpty {
                    Text(fileDirectory(for: file))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if let diff = diffs[file.id] {
                let lines = Self.displayLines(diff.text)
                let additions = lines.filter { $0.kind == .addition }.count
                let deletions = lines.filter { $0.kind == .deletion }.count
                HStack(spacing: 5) {
                    if additions > 0 { Text("+\(additions)").foregroundStyle(Color.dockSuccess) }
                    if deletions > 0 { Text("−\(deletions)").foregroundStyle(Color.dockDestructive) }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .fixedSize()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, showsSelection ? 8 : 0)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background {
            if showsSelection {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).fill(Color.dockAccent.opacity(0.13))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .contentShape(Rectangle())
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
        if file.status == .untracked { return .dockSecondaryText }
        return .dockWarning
    }

    private func toggle(_ file: RepositoryFileChange) {
        if expandedFileIDs.remove(file.id) == nil {
            expandedFileIDs.insert(file.id)
            if diffs[file.id] == nil { loadDiff(for: file) }
        }
    }

    private func loadDiff(for file: RepositoryFileChange) {
        guard loadingFileIDs.insert(file.id).inserted else { return }
        Task {
            let diff = await RepositoryService.diff(path: workflow.repository.path, file: file)
            loadingFileIDs.remove(file.id)
            diffs[file.id] = diff
        }
    }

    private func emptyState(icon: Ph, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockIconLabel(title, icon: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

    }
}
