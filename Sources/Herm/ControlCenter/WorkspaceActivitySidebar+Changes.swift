import AppKit
import ServiceManagement
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    var changesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("CHANGE REVIEW")
            if let codeWorkspaceError {
                Text(codeWorkspaceError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dockWarning.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            }
            if let review = workflow.review {
                HStack(spacing: 8) {
                    todayMetric("BLOCKERS", value: review.blockerCount, color: review.blockerCount > 0 ? .dockDestructive : .dockSuccess)
                    todayMetric("WARNINGS", value: review.warningCount, color: review.warningCount > 0 ? .dockWarning : .dockSuccess)
                    todayMetric("NOTES", value: review.noteCount, color: .dockSecondaryText)
                    Text(review.completeness == .complete ? "COMPLETE" : "PARTIAL")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(review.completeness == .complete ? Color.dockSuccess : Color.dockWarning)
                }
                HStack(spacing: 10) {
                    Button("RUN LOCAL REVIEW") { Task { await workflow.runReview(preferences: commandCenterPreferences) } }
                    Button("SAVE BASELINE") { workflow.saveReviewBaseline(preferences: commandCenterPreferences, acknowledgedFindingIDs: review.findings.map(\.id)) }
                        .disabled(!workflow.canSaveReviewBaseline)
                    Button("REVIEW WITH HERMES") {
                        let prompt = "Review the current repository changes without editing files. Local findings: \(review.blockerCount) blockers, \(review.warningCount) warnings, \(review.noteCount) notes. Inspect safely and report risks, missing tests, and verification scope."
                        Task { _ = await control.startBackgroundTask(prompt, kind: .review) }
                    }
                }
                .buttonStyle(.dockHover)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
                switch workflow.baselineStatus {
                case .current(let date):
                    Text("BASELINE CURRENT · \(HumanDateFormatting.dateAndTime(date))").foregroundStyle(Color.dockSuccess)
                case .stale(let date):
                    Text("BASELINE STALE · \(HumanDateFormatting.dateAndTime(date))").foregroundStyle(Color.dockWarning)
                case .partial(let date):
                    Text("PARTIAL BASELINE · \(HumanDateFormatting.dateAndTime(date))").foregroundStyle(Color.dockWarning)
                case .none:
                    EmptyView()
                }
            } else {
                Button("RUN LOCAL REVIEW") { Task { await workflow.runReview(preferences: commandCenterPreferences) } }
                    .buttonStyle(.dockHover)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
            }
            // The repository browser owns the unloaded/loading state. Once
            // the workflow snapshot matches the session's resolved project,
            // render the browser; otherwise let the branches below explain
            // the repository or loading state instead of treating every
            // snapshot as a match.
            if workflow.repository.path == activeRepositoryPath {
                RepositoryChangesBrowser(
                    model: model,
                    workflow: workflow,
                    projectPath: activeRepositoryPath,
                    onRefresh: { await refreshRepository() },
                    onSelectProjectFolder: { showingRepositoryPicker = true }
                )
            } else if let changes = workflow.changes, workflow.repository.isGitRepository {
                HStack(spacing: 8) {
                    todayMetric("STAGED", value: changes.stagedCount, color: .dockAccent)
                    todayMetric("UNSTAGED", value: changes.unstagedCount, color: .dockWarning)
                    todayMetric("UNTRACKED", value: changes.untrackedCount, color: .dockSecondaryText)
                    todayMetric("CONFLICTS", value: changes.conflictedCount, color: changes.conflictedCount > 0 ? .dockDestructive : .dockSuccess)
                }
                if changes.files.isEmpty {
                    emptyState(icon: .checkCircle, title: "Working tree clean", detail: "No staged, unstaged, or untracked files were found.")
                } else {
                    changeSections(changes)
                }
            } else if let path = activeRepositoryPath {
                let inspecting = isRefreshingRepository || workflow.isRefreshing
                emptyState(
                    icon: inspecting ? .arrowsClockwise : .folder,
                    title: inspecting ? "Inspecting project" : "Project is not a Git repository",
                    detail: inspecting ? path : "\(path) is available as a local project folder, but it has no Git working tree to inspect."
                )
            } else {
                emptyState(icon: .fileMagnifyingGlass, title: "No project selected", detail: "Choose a project from Projects to inspect its local changes.")
                Button("SELECT PROJECT FOLDER") {
                    showingRepositoryPicker = true
                }
                .buttonStyle(.dockHover)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
        }
    }

    @ViewBuilder
    func changeSections(_ changes: RepositoryChangeSnapshot) -> some View {
        let staged = changes.files.filter(\.isStaged)
        let unstaged = changes.files.filter { !$0.isStaged && $0.status != .untracked }
        let untracked = changes.files.filter { $0.status == .untracked }
        changeSection("STAGED", files: staged, color: .dockAccent)
        changeSection("UNSTAGED", files: unstaged, color: .dockWarning)
        changeSection("UNTRACKED", files: untracked, color: .dockSecondaryText)
    }

    @ViewBuilder
    func changeSection(_ title: String, files: [RepositoryFileChange], color: Color) -> some View {
        if !files.isEmpty {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6)
                sectionLabel("\(title)  ·  \(files.count)")
            }
            ForEach(files) { file in
                changeFileRow(file)
            }
        }
    }

    func changeFileRow(_ file: RepositoryFileChange) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let diff = selectedRepositoryDiff, diff.path == file.path, diff.isStaged == file.isStaged {
                    Text(diff.text.isEmpty ? "No textual diff is available for this file." : diff.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                    if diff.isTruncated { Text("Diff truncated for safe display.").font(.system(size: 12)).foregroundStyle(Color.dockWarning) }
                    diffAuditSummary(diff)
                } else {
                    Button(isLoadingRepositoryDiff ? "LOADING DIFF…" : "LOAD DIFF") { loadRepositoryDiff(for: file) }
                        .buttonStyle(.dockHover)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(isLoadingRepositoryDiff)
                }
                let writers = model.activeSubagents.filter { $0.filesWritten.contains(file.path) }

                if workflow.isReviewCovered(file) {
                    Button(workflow.isReviewed(file) ? "REVIEWED" : "MARK REVIEWED") { workflow.toggleReviewed(file) }
                        .buttonStyle(.dockHover)
                        .foregroundStyle(workflow.isReviewed(file) ? Color.dockSuccess : Color.dockAccent)
                }
                Text(writers.isEmpty
                    ? "UNATTRIBUTED LOCAL CHANGE"
                    : "HERMES REPORTED WRITE · " + writers.map { $0.name ?? $0.role ?? $0.id }.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(writers.isEmpty ? Color.dockMetadataText : Color.dockAccent)
            }
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                DockIcon(file.status == .conflicted ? .warningOctagon : .file)
                    .foregroundStyle(file.status == .conflicted ? Color.dockDestructive : file.isStaged ? Color.dockAccent : Color.dockSecondaryText)
                Text(file.path).lineLimit(1).foregroundStyle(Color.dockPrimaryText)
                Spacer()
                Text(file.isStaged ? "STAGED" : file.status.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockMetadataText)
            }
            .font(.system(size: 12))
        }
        .dockListRow()
    }

    func loadRepositoryDiff(for file: RepositoryFileChange) {
        Task {
            isLoadingRepositoryDiff = true
            selectedRepositoryDiff = await RepositoryService.diff(path: workflow.repository.path, file: file)
            isLoadingRepositoryDiff = false
        }
    }

    @ViewBuilder
    func diffAuditSummary(_ diff: RepositoryDiff) -> some View {
        let findings = RepositoryDiffAuditor.audit(diff)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                DockIcon(findings.isEmpty ? .shieldCheck : .shieldWarning)
                Text(findings.isEmpty ? "LOCAL AUDIT · NO OBVIOUS SIGNALS" : "LOCAL AUDIT · \(findings.count) SIGNAL\(findings.count == 1 ? "" : "S")")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(findings.contains(where: { $0.severity == .blocker }) ? Color.dockDestructive : findings.isEmpty ? Color.dockSuccess : Color.dockWarning)

            Text("Checks added lines only. It does not replace repository verification or review.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)

            ForEach(findings) { finding in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(finding.severity == .blocker ? Color.dockDestructive : finding.severity == .warning ? Color.dockWarning : Color.dockAccent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(finding.title)\(finding.line.map { " · LINE \($0)" } ?? "")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(finding.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
    }

    var verificationContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("VERIFICATION")
            if let facts = control.projectFacts {
                diagnosticRow(label: "MANIFESTS", value: facts.manifests.isEmpty ? "NONE REPORTED" : facts.manifests.joined(separator: " · "), color: Color.dockSecondaryText)
                diagnosticRow(label: "PACKAGE MANAGERS", value: facts.packageManagers.isEmpty ? "NONE REPORTED" : facts.packageManagers.joined(separator: " · "), color: Color.dockSecondaryText)
                let recipes = VerificationRecipeBuilder.make(facts: facts, repository: workflow.repository)
                if !recipes.isEmpty {
                    sectionLabel("VERIFIED RECIPES")
                    ForEach(recipes) { recipe in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(recipe.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
                            Text(recipe.command).font(.system(size: 12)).foregroundStyle(Color.dockPrimaryText).textSelection(.enabled)
                            Button("RUN IN BACKGROUND") {
                                guard let path = activeRepositoryPath else { return }
                                let prompt = "Run this exact verification command in " + path + ": " + recipe.command + ". Do not edit files. Report the result, evidence scope, and exit code."
                                Task { _ = await control.startBackgroundTask(prompt, kind: .verification) }
                            }
                            .buttonStyle(.dockHover).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockAccent)
                        }
                        .dockListRow()
                    }
                }
            }
                if let verification = control.verification {
                let deliveryEvidence = VerificationEvidencePresentation.make(verification: verification, currentFingerprint: workflow.repository.headRevision, evidenceFingerprint: nil, currentRepositoryIdentity: workflow.repository.repositoryID, currentCommitFingerprint: workflow.repository.headRevision, openFailureCount: control.attention.filter { $0.state == .open && $0.kind == .failure }.count, repositoryDirty: workflow.repository.changedFiles > 0)
                diagnosticRow(label: "DELIVERY", value: deliveryEvidence.title.uppercased(), color: deliveryEvidence.state == .current ? .dockSuccess : .dockWarning)
                Text(deliveryEvidence.nextAction)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
                let color: Color = verification.state == .passed ? .dockSuccess : verification.state == .failed ? .dockDestructive : .dockWarning
                diagnosticRow(label: "STATUS", value: verification.state.rawValue.uppercased(), color: color)
                if let evidence = verification.evidence {
                    diagnosticRow(label: "SCOPE", value: evidence.scope?.uppercased() ?? "UNKNOWN", color: evidence.scope?.lowercased() == "targeted" ? .dockWarning : .dockSecondaryText)
                    if let command = evidence.canonicalCommand ?? evidence.command { diagnosticRow(label: "EVIDENCE", value: command, color: .dockMetadataText) }
                    if let adapter = evidence.adapter { diagnosticRow(label: "ADAPTER", value: adapter, color: .dockMetadataText) }
                    if let capturedAt = evidence.capturedAt { diagnosticRow(label: "CAPTURED", value: ISO8601DateFormatter().string(from: capturedAt), color: .dockMetadataText) }
                    if let repository = evidence.repositoryIdentity { diagnosticRow(label: "REPOSITORY", value: repository, color: .dockMetadataText) }
                    if let commit = evidence.commitFingerprint { diagnosticRow(label: "COMMIT", value: commit, color: .dockMetadataText) }
                    if let target = evidence.targetFingerprint { diagnosticRow(label: "TARGET", value: target, color: .dockMetadataText) }
                    if let diff = evidence.diffFingerprint { diagnosticRow(label: "DIFF", value: diff, color: .dockMetadataText) }
                    if let rules = evidence.rulesScopeDetail { diagnosticRow(label: "RULES", value: rules, color: .dockMetadataText) }
                    if let staleReason = deliveryEvidence.staleReason { diagnosticRow(label: "STALE", value: staleReason, color: .dockWarning) }
                }
            } else if control.projectFacts == nil {
                emptyState(icon: .sealCheck, title: "Verification unavailable", detail: "Open a Hermes project session with a local folder, then refresh Settings to request verification facts.")
            }
        }
    }

    var repositoriesContent: some View {
        let paths = Array(Set(store.tasks.compactMap(\.projectPath) + [store.projectPath].compactMap { $0 })).sorted()
        return VStack(alignment: .leading, spacing: 22) {
            sectionLabel("REPOSITORY FLEET  ·  \(paths.count)")
            Text("Repositories are local read-only references attached to Hermes sessions. No remotes are fetched automatically.")
                .font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
            if workflow.repository.isGitRepository {
                HStack(spacing: 10) {
                    Button(commandCenterPreferences.isWatchingRepository(workflow.repository.repositoryID) ? "STOP WATCHING" : "WATCH REPOSITORY") {
                        workflow.toggleWatching(preferences: commandCenterPreferences, control: control)
                    }
                    Button("REFRESH FLEET") { Task { await workflow.refresh(preferences: commandCenterPreferences, control: control) } }
                    if case .watching = workflow.watchState {
                        Text("WATCHING").foregroundStyle(Color.dockSuccess)
                    } else if case .stale(let detail) = workflow.watchState {
                        Text(detail).lineLimit(1).foregroundStyle(Color.dockWarning)
                    }
                }
                .buttonStyle(.dockHover)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
            if !workflow.notices.isEmpty {
                sectionLabel("RECENT REPOSITORY CHANGES")
                ForEach(workflow.notices) { notice in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(notice.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
                        Text("\(notice.changedFiles) changed file\(notice.changedFiles == 1 ? "" : "s") · \(HumanDateFormatting.dateAndTime(notice.createdAt))")
                            .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                        HStack(spacing: 10) {
                            Button("OPEN SOURCE CONTROL") { select(.changes) }
                            Button("REVIEW WITH HERMES") {
                                let prompt = "Review repository \(notice.displayName) without editing files. Herm detected \(notice.changedFiles) changed files. Report risks, missing tests, and verification scope without quoting suspected credential values."
                                Task { _ = await control.startBackgroundTask(prompt, kind: .review) }
                            }
                            Button("OPEN VERIFICATION") { select(.verification) }
                        }
                        .buttonStyle(.dockHover)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                    }
                    .dockListRow()
                }
            }
            if paths.isEmpty {
                emptyState(icon: .folder, title: "No repositories attached", detail: "Use Change Repository from Today to attach a local repository to a Hermes session.")
            } else {
                if !workflow.worktrees.isEmpty {
                    DisclosureGroup("WORKTREES  ·  \(workflow.worktrees.count)") {
                        ForEach(workflow.worktrees) { worktree in
                            HStack(spacing: 8) {
                                DockIcon(worktree.snapshot?.conflictedFiles ?? 0 > 0 ? .warningOctagon : .gitBranch)
                                    .foregroundStyle(worktree.snapshot?.conflictedFiles ?? 0 > 0 ? Color.dockDestructive : Color.dockAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worktree.displayName).foregroundStyle(Color.dockPrimaryText)
                                    Text(worktree.branch ?? "DETACHED HEAD").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                                }
                                Spacer()
                                Text("\(worktree.snapshot?.changedFiles ?? 0) CHANGED").font(.system(size: 10)).foregroundStyle(Color.dockSecondaryText)
                                Button("USE") { store.attachProject(at: worktree.path, toSessionID: model.sessionID) }
                            }
                            .font(.system(size: 12))
                            .dockListRow()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
                ForEach(paths, id: \.self) { path in
                    RepositoryFleetRow(path: path, activePath: activeRepositoryPath) { selected in
                        store.attachProject(at: selected, toSessionID: model.sessionID)
                    }
                }
            }
        }
    }
}
