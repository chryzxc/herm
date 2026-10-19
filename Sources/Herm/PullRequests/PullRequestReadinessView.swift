import SwiftUI

struct PullRequestReadinessView: View {
    @ObservedObject var center: PullRequestCenterModel
    let record: PullRequestRecord
    @State private var analysis: GitHubConflictAnalysis?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analyzing = false
    @State private var preparingResolution = false
    @State private var error: String?
    @Environment(\.chatContextRouter) private var chatRouter
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DockSectionHeader(title: "Readiness", style: style) {
                if let date = record.refreshedAt {
                    Text("Updated \(HumanDateFormatting.relative(date))")
                        .font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1).fixedSize()
                        .help(date.formatted(date: .abbreviated, time: .standard))
                }
                DockIconButton(icon: .arrowsClockwise, label: "Refresh readiness", isBusy: center.isLoadingDetail(for: record.id), size: 24, style: style) { Task { await center.refreshSelectedDetail() } }
            }
            fact("State", record.mergedAt != nil ? "Merged" : (record.state == "closed" ? "Closed" : (record.isDraft ? "Draft · not ready for review" : "Open")))
            fact("Checks", record.checksSummary)
            fact("Review", reviewLabel)
            fact("Merge", mergeLabel, warning: record.isOpenForWork && record.mergeability == .conflicting)
            if let warning = record.detailWarning { Text(warning).foregroundStyle(Color.dockWarning) }
            if record.isOpenForWork && (record.mergeability == .conflicting || analyzing) {
                Divider().overlay(Color.dockBorderLight)
                DockChipFlow(spacing: 8) {
                    if record.canAnalyzeConflicts || analyzing {
                        Button {
                            if analyzing { analysisTask?.cancel() } else { analyze() }
                        } label: {
                            HStack(spacing: 6) {
                                if analyzing { ProgressView().controlSize(.mini) }
                                Text(analyzing ? "Cancel analysis" : "Analyze conflict files")
                            }
                        }.buttonStyle(.dockCompact)
                    }
                    if record.mergeability == .conflicting, chatRouter != nil {
                        Button { Task { await prepareResolution() } } label: { GitHubActionLabel(title: preparingResolution ? "Preparing…" : "Prepare resolution in Hermes", isBusy: preparingResolution) }
                            .buttonStyle(.dockCompact).disabled(preparingResolution)
                    }
                    Link(destination: record.reference.webURL) {
                        HStack(spacing: 6) {
                            Text("View on GitHub")
                            DockIcon(.arrowSquareOut, size: 12, color: Color.dockSecondaryText)
                        }
                    }.buttonStyle(.dockCompact)
                }
            }
            if let analysis {
                if !analysis.matches(record) {
                    Text("Conflict analysis is outdated. Analyze the current revisions again.").foregroundStyle(Color.dockWarning)
                } else {
                    Text("Local analysis · \(String(analysis.headRevision.prefix(7))) into \(String(analysis.baseRevision.prefix(7)))")
                        .font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText)
                    if analysis.hasConflicts {
                        ForEach(analysis.files, id: \.self) { path in Text(path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                        if !analysis.complete { Text("Git reported a conflict without a complete file list. Open on GitHub for details.").foregroundStyle(Color.dockWarning) }
                    } else { Text("No conflicts found for these revisions. GitHub readiness is shown separately.").foregroundStyle(Color.dockSecondaryText) }
                }
            }
            if let error { Text(error).foregroundStyle(Color.dockWarning) }
        }
        .font(DockTypography.body).foregroundStyle(Color.dockPrimaryText).tint(Color.dockAccent).dockCard(padding: 12)
        .onChange(of: record.id) { _, _ in analysisTask?.cancel(); analysis = nil; error = nil }
        .onDisappear { analysisTask?.cancel() }
    }
    private func fact(_ title: String, _ value: String, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(Color.dockMetadataText).frame(width: 104, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if warning { DockIcon(.warningCircle, size: 13, color: Color.dockWarning).accessibilityHidden(true) }
                Text(value).fontWeight(.regular).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(warning ? Color.dockWarning : Color.dockPrimaryText)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 2)
    }
    private var reviewLabel: String {
        if !record.isOpenForWork { return record.reviews.isEmpty ? "No reviews" : "\(record.reviews.count) reviews" }
        switch record.reviewDecision {
        case "APPROVED": return "Required review approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        case "REVIEW_REQUIRED": return "Review required"
        default: return "Review requirements unavailable"
        }
    }
    private var mergeLabel: String {
        if record.mergedAt != nil { return "Merged" }
        if record.state == "closed" { return "Closed" }
        switch record.mergeability {
        case .conflicting: return "Conflicts must be resolved"
        case .mergeable: return "No merge conflicts"
        case .unknown: return "Mergeability is being calculated or is unavailable. Refresh to check again."
        }
    }
    private func analyze() {
        guard record.canAnalyzeConflicts else { return }
        analyzing = true; error = nil
        let snapshot = record
        analysisTask = Task {
            defer { analyzing = false }
            do {
                let result = try await GitHubConflictService().analyze(snapshot)
                guard !Task.isCancelled, snapshot.id == center.selectedID else { return }
                analysis = result
                await center.refreshSelectedDetail()
            } catch is CancellationError {} catch {
                if !Task.isCancelled, snapshot.id == center.selectedID { self.error = error.localizedDescription }
            }
        }
    }
    private func prepareResolution() async {
        guard record.isOpenForWork, record.mergeability == .conflicting, !preparingResolution else { return }
        preparingResolution = true; defer { preparingResolution = false }
        var path = record.localPath
        if path.isEmpty {
            let panel = NSOpenPanel(); panel.title = "Choose the local repository for this PR"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            guard panel.runAboveHerm() == .OK, let url = panel.url else { return }; path = url.path
        }
        guard let remote = await RepositoryService.githubRemote(path: path), remote.id.caseInsensitiveCompare(record.repository.id) == .orderedSame else {
            error = "Choose a local repository or worktree whose GitHub remote matches \(record.repository.id)."; return
        }
        let files = analysis.flatMap { $0.matches(record) ? $0.files : nil } ?? []
        let context = ChatContext(id: "conflicts:" + record.id, title: "Resolve conflicts in PR #\(record.displayNumber)", body: """
        Prepare conflict resolution for \(record.reference.title): \(record.title).
        PR: \(record.reference.webURL.absoluteString)
        Head: \(record.headBranch) @ \(record.headRevision ?? "unknown")
        Base: \(record.baseBranch) @ \(record.baseRevision ?? "unknown")
        Conflict files from matching local analysis: \(files.isEmpty ? "Not available; inspect before resolving." : files.joined(separator: ", "))
        Inspect this repository and the current revisions before making changes. Preserve existing work, resolve the conflicts, and run relevant verification. Do not commit, push, or merge unless I explicitly ask.
        """, projectPath: path)
        chatRouter?.attach(context, to: nil)
    }
}
