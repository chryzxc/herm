import SwiftUI

enum GitHubMergeMethod: String, CaseIterable, Identifiable, Sendable {
    case merge = "MERGE", squash = "SQUASH", rebase = "REBASE"
    var id: Self { self }
    var title: String { switch self { case .merge: "Merge commit"; case .squash: "Squash and merge"; case .rebase: "Rebase and merge" } }
}
enum GitHubLandingAction: String, Identifiable, Sendable {
    case merge = "Merge pull request", auto = "Enable auto-merge", disableAuto = "Disable auto-merge", enqueue = "Add to merge queue", dequeue = "Remove from merge queue"
    var id: Self { self }
}
struct GitHubLandingSnapshot: Equatable, Sendable {
    let id: String
    let head: String
    let state: String
    let draft: Bool
    let mergeable: String
    let mergeState: String
    let reviewDecision: String?
    let canMerge: Bool
    let canAuto: Bool
    let canDisableAuto: Bool
    let queueEnabled: Bool
    let queued: Bool
    let autoEnabled: Bool
    let methods: [GitHubMergeMethod]
    var mergedAt: Date? = nil
    var updatedAt: Date? = nil
    var canMergeNow: Bool { canMerge && state == "OPEN" && !draft && mergeable == "MERGEABLE" && ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(mergeState) && !queueEnabled && reviewDecision != "CHANGES_REQUESTED" && reviewDecision != "REVIEW_REQUIRED" }
    func mergeBlockers(for record: PullRequestRecord) -> [String] {
        guard state == "OPEN" else { return [state == "MERGED" ? "This pull request is already merged." : state == "CLOSED" ? "Reopen this pull request before merging." : "Pull request state is unavailable. Refresh to retry."] }
        var blockers: [String] = []
        if head != record.headRevision { blockers.append("The PR head changed. Refresh before merging.") }
        if !canMerge { blockers.append("You do not have permission to merge this pull request.") }
        if draft { blockers.append("Mark this draft ready for review before merging.") }
        if methods.isEmpty && !queueEnabled { blockers.append("No merge methods are available for this repository.") }
        if queueEnabled { blockers.append(queued ? "This pull request is waiting in the merge queue." : "This repository requires the merge queue.") }
        if mergeable == "CONFLICTING" || mergeState == "DIRTY" {
            blockers.append("Resolve merge conflicts before merging.")
        } else if mergeable != "MERGEABLE" {
            blockers.append("GitHub has not confirmed mergeability. Refresh to check again.")
        }
        switch reviewDecision {
        case "CHANGES_REQUESTED": blockers.append("A reviewer requested changes.")
        case "REVIEW_REQUIRED": blockers.append("Required approving reviews are still missing.")
        default: break
        }
        switch mergeState {
        case "BEHIND": blockers.append("Update the PR branch with the latest base branch changes.")
        case "BLOCKED" where reviewDecision != "REVIEW_REQUIRED" && reviewDecision != "CHANGES_REQUESTED":
            blockers.append("GitHub reports an unmet repository rule. Open on GitHub to see the exact requirement.")
        case "UNKNOWN" where mergeable == "MERGEABLE": blockers.append("GitHub is still calculating merge requirements. Refresh to check again.")
        case "CLEAN", "HAS_HOOKS", "DIRTY", "BLOCKED", "UNSTABLE", "UNKNOWN": break
        default: blockers.append("GitHub reports an additional merge restriction (\(mergeState.replacingOccurrences(of: "_", with: " ").lowercased())).")
        }
        return blockers
    }
    func checkWarnings(for record: PullRequestRecord) -> [String] {
        var warnings: [String] = []
        let failed = record.checks.filter(\.isFailure)
        let pending = record.checks.filter(\.isPending)
        if !failed.isEmpty { warnings.append("Failing checks: " + failed.map(\.name).joined(separator: ", ") + ".") }
        if !pending.isEmpty { warnings.append("Waiting for checks: " + pending.map(\.name).joined(separator: ", ") + ".") }
        if !record.checksAvailable { warnings.append("Check status is incomplete or unavailable. Refresh to retry.") }
        else if record.checks.contains(where: { !$0.isSuccess && !$0.isFailure && !$0.isPending }) { warnings.append("Some check results are unknown. Refresh to retry.") }
        if mergeState == "UNSTABLE", failed.isEmpty, pending.isEmpty { warnings.append("GitHub reports non-passing checks.") }
        return warnings
    }
    var status: String { state == "MERGED" ? "Merged" : state == "CLOSED" ? "Closed" : queued ? "Queued · waiting for GitHub" : autoEnabled ? "Auto-merge enabled · waiting for requirements" : "" }
}
struct GitHubLandingService: Sendable {
    let client: GitHubClient
    func snapshot(_ record: PullRequestRecord) async throws -> GitHubLandingSnapshot {
        guard let id = record.nodeID else { throw GitHubRequestError.unavailable }
        let data = try await client.graphQL("query($id:ID!){node(id:$id){... on PullRequest{\(Self.fields)}}}", variables: ["id": id])
        guard let row = data["node"] as? [String: Any] else { throw GitHubRequestError.malformed }
        return try decode(row, record: record)
    }
    private static let fields = "id headRefOid state isDraft mergedAt updatedAt mergeable mergeStateStatus reviewDecision viewerCanEnableAutoMerge viewerCanDisableAutoMerge isMergeQueueEnabled isInMergeQueue autoMergeRequest{enabledAt} repository{viewerPermission mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed}"
    private func decode(_ row: [String: Any], record: PullRequestRecord) throws -> GitHubLandingSnapshot {
        guard let id = record.nodeID, let head = row["headRefOid"] as? String, head == record.headRevision, let repo = row["repository"] as? [String: Any] else { throw GitHubRequestError.changed }
        let methods = GitHubMergeMethod.allCases.filter { method in repo[method == .merge ? "mergeCommitAllowed" : method == .squash ? "squashMergeAllowed" : "rebaseMergeAllowed"] as? Bool == true }
        return GitHubLandingSnapshot(id: id, head: head, state: row["state"] as? String ?? "UNKNOWN", draft: row["isDraft"] as? Bool ?? true, mergeable: row["mergeable"] as? String ?? "UNKNOWN", mergeState: row["mergeStateStatus"] as? String ?? "UNKNOWN", reviewDecision: row["reviewDecision"] as? String, canMerge: ["WRITE", "MAINTAIN", "ADMIN"].contains(repo["viewerPermission"] as? String ?? ""), canAuto: row["viewerCanEnableAutoMerge"] as? Bool ?? false, canDisableAuto: row["viewerCanDisableAutoMerge"] as? Bool ?? false, queueEnabled: row["isMergeQueueEnabled"] as? Bool ?? false, queued: row["isInMergeQueue"] as? Bool ?? false, autoEnabled: row["autoMergeRequest"] is [String: Any], methods: methods, mergedAt: (row["mergedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }, updatedAt: (row["updatedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
    }
    func perform(_ action: GitHubLandingAction, method: GitHubMergeMethod, record: PullRequestRecord, confirmed: GitHubLandingSnapshot) async throws -> GitHubLandingSnapshot {
        let fresh = try await snapshot(record)
        guard fresh == confirmed else { throw GitHubRequestError.changed }
        guard fresh.state == "OPEN", !fresh.draft, fresh.head == record.headRevision else { throw GitHubRequestError.changed }
        let operation: String
        var input: [String: Any] = ["pullRequestId": fresh.id]
        switch action {
        case .merge:
            guard fresh.canMergeNow, fresh.methods.contains(method) else { throw GitHubRequestError.forbidden }
            operation = "mergePullRequest"; input["expectedHeadOid"] = fresh.head; input["mergeMethod"] = method.rawValue
        case .auto:
            guard fresh.canAuto, fresh.methods.contains(method), !fresh.autoEnabled else { throw GitHubRequestError.forbidden }
            operation = "enablePullRequestAutoMerge"; input["expectedHeadOid"] = fresh.head; input["mergeMethod"] = method.rawValue
        case .disableAuto:
            guard fresh.canDisableAuto, fresh.autoEnabled else { throw GitHubRequestError.forbidden }; operation = "disablePullRequestAutoMerge"
        case .enqueue:
            guard fresh.canMerge, fresh.queueEnabled, !fresh.queued, fresh.mergeable == "MERGEABLE", fresh.reviewDecision != "CHANGES_REQUESTED" else { throw GitHubRequestError.forbidden }
            operation = "enqueuePullRequest"; input["expectedHeadOid"] = fresh.head
        case .dequeue:
            guard fresh.canMerge, fresh.queued else { throw GitHubRequestError.forbidden }; operation = "dequeuePullRequest"
        }
        let fields = action == .merge ? "pullRequest{\(Self.fields)}" : "clientMutationId"
        let data = try await client.graphQL("mutation($input:\(operation.prefix(1).uppercased() + operation.dropFirst())Input!){\(operation)(input:$input){\(fields)}}", variables: ["input": input])
        if action == .merge {
            guard let payload = data[operation] as? [String: Any], let row = payload["pullRequest"] as? [String: Any] else { throw GitHubRequestError.malformed }
            let updated = try decode(row, record: record)
            guard updated.state != "MERGED" || updated.mergedAt != nil else { throw GitHubRequestError.malformed }
            return updated
        }
        return try await snapshot(record)
    }
}

struct PullRequestLandingView: View {
    let record: PullRequestRecord
    let client: GitHubClient
    var onLanded: ((GitHubLandingSnapshot) -> Void)? = nil
    let onChanged: () -> Void
    @State private var snapshot: GitHubLandingSnapshot?
    @State private var method: GitHubMergeMethod = .merge
    @State private var pending: GitHubLandingAction?
    @State private var confirmed: GitHubLandingSnapshot?
    @State private var busy = false
    @State private var activeAction: GitHubLandingAction?
    @State private var loading = false
    @State private var loadGeneration = UUID()
    @State private var error: String?
    @State private var result: String?
    private var service: GitHubLandingService { GitHubLandingService(client: client) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DockSectionHeader(title: record.mergedAt != nil ? "Pull request merged" : "Merge pull request", style: DockThemePalette(theme: DockThemeRuntime.current)) {
                if record.mergedAt == nil {
                    DockIconButton(icon: .arrowsClockwise, label: "Refresh merge requirements", isBusy: busy || loading, size: 24, style: DockThemePalette(theme: DockThemeRuntime.current)) { Task { await load() } }
                }
            }
            if record.mergedAt != nil {
                GitHubBranchCleanupView(record: record, client: client)
            } else if let snapshot {
                if !snapshot.status.isEmpty { Text(snapshot.status).foregroundStyle(Color.dockSecondaryText) }
                if snapshot.state == "OPEN" && !snapshot.draft && (snapshot.canMerge || snapshot.canAuto || snapshot.canDisableAuto) {
                    DockChipFlow(spacing: 8) {
                        if !snapshot.methods.isEmpty && !snapshot.queueEnabled {
                            DockMenu {
                                ForEach(snapshot.methods) { option in
                                    Button(option.title) { method = option }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(method.title).fontWeight(.regular)
                                    DockIcon(.caretDown, size: 12, color: Color.dockSecondaryText)
                                }
                                .font(DockTypography.body).padding(.horizontal, 10).frame(height: 28)
                                .background(DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(Color.dockControlSurface.opacity(0.6)))
                            }
                            .disabled(busy || loading).help("Merge method").accessibilityLabel("Merge method: \(method.title)")
                        }
                        if snapshot.queueEnabled {
                            actionButton(snapshot.queued ? .dequeue : .enqueue, enabled: snapshot.canMerge && (snapshot.queued || (snapshot.mergeable == "MERGEABLE" && snapshot.reviewDecision != "CHANGES_REQUESTED")))
                        } else {
                            actionButton(.merge, enabled: snapshot.canMergeNow && snapshot.methods.contains(method))
                        }
                        if snapshot.canDisableAuto && snapshot.autoEnabled { actionButton(.disableAuto, enabled: true) }
                        else if snapshot.canAuto && !snapshot.queueEnabled { actionButton(.auto, enabled: !snapshot.methods.isEmpty) }
                    }
                }
                let blockers = snapshot.mergeBlockers(for: record)
                let warnings = snapshot.checkWarnings(for: record)
                if !blockers.isEmpty || !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider().overlay(Color.dockBorderLight)
                        ForEach(blockers, id: \.self) { blocker in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                DockIcon(.warningCircle, size: 13, color: Color.dockWarning)
                                    .accessibilityHidden(true)
                                Text(blocker).textSelection(.enabled)
                            }
                        }
                        ForEach(warnings, id: \.self) { warning in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                DockIcon(.warningCircle, size: 13, color: Color.dockWarning).accessibilityHidden(true)
                                Text(warning).textSelection(.enabled)
                            }
                        }
                        Link(destination: record.reference.webURL) {
                            HStack(spacing: 6) {
                                Text(blockers.isEmpty ? "View checks on GitHub" : "View requirements on GitHub")
                                DockIcon(.arrowSquareOut, size: 12, color: Color.dockSecondaryText)
                            }
                        }
                        .buttonStyle(.dockCompact)
                        .controlSize(.small)
                    }.foregroundStyle(Color.dockSecondaryText)
                }
            }
            if record.mergedAt == nil, let result { Text(result).foregroundStyle(Color.dockSecondaryText) }
            if let error { Text(error).foregroundStyle(Color.dockWarning) }
        }.font(DockTypography.body).foregroundStyle(Color.dockPrimaryText).dockCard(padding: 12)
        .task(id: "\(record.id):\(record.headRevision ?? ""): \(record.refreshedAt?.timeIntervalSince1970 ?? 0)") { await load() }
        .confirmationDialog(pending?.rawValue ?? "Confirm GitHub action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil; confirmed = nil } }), titleVisibility: .visible, presenting: confirmed.flatMap { snapshot in pending.map { ($0, snapshot, method) } }) { request in
            Button(request.0.rawValue) {
                pending = nil; confirmed = nil
                Task { await perform(request.0, original: request.1, method: request.2) }
            }
            Button("Cancel", role: .cancel) { pending = nil; confirmed = nil }
        } message: { request in Text("\(record.reference.title) · \(record.title)\nHead: \(record.headRevision ?? "unknown")\n\(request.2.title)\nGitHub enforces repository rules. Queued and auto-merge requests may wait before merging.\n\(request.1.checkWarnings(for: record).joined(separator: "\n"))") }
    }
    @ViewBuilder
    private func actionButton(_ action: GitHubLandingAction, enabled: Bool) -> some View {
        let button = Button { confirmed = snapshot; pending = action } label: {
            GitHubActionLabel(title: action.rawValue, isBusy: activeAction == action)
        }.disabled(!enabled || busy || loading)
        if action == .merge { button.buttonStyle(.dockPrimary).controlSize(.small) }
        else { button.buttonStyle(.dockCompact) }
    }
    private func load() async {
        guard !busy, record.mergedAt == nil else { return }
        let generation = UUID(); loadGeneration = generation; loading = true
        defer { if loadGeneration == generation { loading = false } }
        do {
            let updated = try await service.snapshot(record)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            snapshot = updated
            if let first = updated.methods.first, !updated.methods.contains(method) { method = first }
            error = nil
        } catch {
            if generation == loadGeneration, !Task.isCancelled { self.error = error.localizedDescription; snapshot = nil }
        }
    }
    private func perform(_ action: GitHubLandingAction, original: GitHubLandingSnapshot, method: GitHubMergeMethod) async {
        busy = true; activeAction = action; result = "Requesting GitHub action…"; defer { busy = false; activeAction = nil }
        do {
            let updated = try await service.perform(action, method: method, record: record, confirmed: original)
            onLanded?(updated)
            snapshot = updated; result = updated.status.isEmpty ? "Request accepted. Refreshing GitHub state…" : updated.status; error = nil; onChanged()
        } catch { result = nil; self.error = error.localizedDescription; onChanged() }
    }
}
