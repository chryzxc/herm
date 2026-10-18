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
    var canMergeNow: Bool { canMerge && state == "OPEN" && !draft && mergeable == "MERGEABLE" && ["CLEAN", "HAS_HOOKS"].contains(mergeState) && !queueEnabled && reviewDecision != "CHANGES_REQUESTED" && reviewDecision != "REVIEW_REQUIRED" }
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
        let failed = record.checks.filter(\.isFailure)
        let pending = record.checks.filter(\.isPending)
        if !failed.isEmpty { blockers.append("Failing checks: " + failed.map(\.name).joined(separator: ", ") + ".") }
        if !pending.isEmpty { blockers.append("Waiting for checks: " + pending.map(\.name).joined(separator: ", ") + ".") }
        if !record.checksAvailable { blockers.append("Check status is incomplete or unavailable. Refresh to retry.") }
        else if record.checks.contains(where: { !$0.isSuccess && !$0.isFailure && !$0.isPending }) { blockers.append("Some check results are unknown. Refresh to retry.") }
        switch mergeState {
        case "BEHIND": blockers.append("Update the PR branch with the latest base branch changes.")
        case "UNSTABLE" where failed.isEmpty: blockers.append("GitHub reports checks that are not passing.")
        case "BLOCKED" where reviewDecision != "REVIEW_REQUIRED" && reviewDecision != "CHANGES_REQUESTED" && failed.isEmpty && pending.isEmpty:
            blockers.append("GitHub reports an unmet repository rule. Open on GitHub to see the exact requirement.")
        case "UNKNOWN" where mergeable == "MERGEABLE": blockers.append("GitHub is still calculating merge requirements. Refresh to check again.")
        case "CLEAN", "HAS_HOOKS", "DIRTY", "BLOCKED", "UNSTABLE", "UNKNOWN": break
        default: blockers.append("GitHub reports an additional merge restriction (\(mergeState.replacingOccurrences(of: "_", with: " ").lowercased())).")
        }
        return blockers
    }
    var status: String { state == "MERGED" ? "Merged" : state == "CLOSED" ? "Closed" : queued ? "Queued · waiting for GitHub" : autoEnabled ? "Auto-merge enabled · waiting for requirements" : "" }
}
struct GitHubLandingService: Sendable {
    let client: GitHubClient
    func snapshot(_ record: PullRequestRecord) async throws -> GitHubLandingSnapshot {
        guard let id = record.nodeID else { throw GitHubRequestError.unavailable }
        let data = try await client.graphQL("query($id:ID!){node(id:$id){... on PullRequest{id headRefOid state isDraft mergeable mergeStateStatus reviewDecision viewerCanEnableAutoMerge viewerCanDisableAutoMerge isMergeQueueEnabled isInMergeQueue autoMergeRequest{enabledAt} repository{viewerPermission mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed}}}}", variables: ["id": id])
        guard let row = data["node"] as? [String: Any], let head = row["headRefOid"] as? String, head == record.headRevision, let repo = row["repository"] as? [String: Any] else { throw GitHubRequestError.changed }
        let methods = GitHubMergeMethod.allCases.filter { method in repo[method == .merge ? "mergeCommitAllowed" : method == .squash ? "squashMergeAllowed" : "rebaseMergeAllowed"] as? Bool == true }
        return GitHubLandingSnapshot(id: id, head: head, state: row["state"] as? String ?? "UNKNOWN", draft: row["isDraft"] as? Bool ?? true, mergeable: row["mergeable"] as? String ?? "UNKNOWN", mergeState: row["mergeStateStatus"] as? String ?? "UNKNOWN", reviewDecision: row["reviewDecision"] as? String, canMerge: ["WRITE", "MAINTAIN", "ADMIN"].contains(repo["viewerPermission"] as? String ?? ""), canAuto: row["viewerCanEnableAutoMerge"] as? Bool ?? false, canDisableAuto: row["viewerCanDisableAutoMerge"] as? Bool ?? false, queueEnabled: row["isMergeQueueEnabled"] as? Bool ?? false, queued: row["isInMergeQueue"] as? Bool ?? false, autoEnabled: row["autoMergeRequest"] is [String: Any], methods: methods)
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
        _ = try await client.graphQL("mutation($input:\(operation.prefix(1).uppercased() + operation.dropFirst())Input!){\(operation)(input:$input){clientMutationId}}", variables: ["input": input])
        return try await snapshot(record)
    }
}

struct PullRequestLandingView: View {
    let record: PullRequestRecord
    let client: GitHubClient
    let onChanged: () -> Void
    @State private var snapshot: GitHubLandingSnapshot?
    @State private var method: GitHubMergeMethod = .merge
    @State private var pending: GitHubLandingAction?
    @State private var confirmed: GitHubLandingSnapshot?
    @State private var busy = false
    @State private var error: String?
    @State private var result: String?
    private var service: GitHubLandingService { GitHubLandingService(client: client) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DockSectionHeader(title: "Land pull request", style: DockThemePalette(theme: DockThemeRuntime.current)) {
                DockIconButton(icon: .arrowsClockwise, label: "Refresh merge requirements", isBusy: busy, size: 24, style: DockThemePalette(theme: DockThemeRuntime.current)) { Task { await load() } }
            }
            if let snapshot {
                if !snapshot.status.isEmpty { Text(snapshot.status).foregroundStyle(Color.dockSecondaryText) }
                if snapshot.state == "OPEN" && !snapshot.draft {
                    DockChipFlow(spacing: 8) {
                        if !snapshot.methods.isEmpty && !snapshot.queueEnabled {
                            Picker("Merge method", selection: $method) { ForEach(snapshot.methods) { Text($0.title).tag($0) } }
                                .pickerStyle(.menu).labelsHidden().controlSize(.small)
                                .help("Merge method")
                        }
                        if snapshot.queueEnabled {
                            actionButton(snapshot.queued ? .dequeue : .enqueue, enabled: snapshot.canMerge && (snapshot.queued || snapshot.mergeable == "MERGEABLE"))
                        } else {
                            actionButton(.merge, enabled: snapshot.canMergeNow && record.checksAvailable && record.checks.allSatisfy(\.isSuccess))
                        }
                        if snapshot.canDisableAuto && snapshot.autoEnabled { actionButton(.disableAuto, enabled: true) }
                        else if snapshot.canAuto && !snapshot.queueEnabled { actionButton(.auto, enabled: !snapshot.methods.isEmpty) }
                    }
                }
                let blockers = snapshot.mergeBlockers(for: record)
                if !blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider().overlay(Color.dockBorderLight)
                        ForEach(blockers, id: \.self) { blocker in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                DockIcon(.warningCircle, size: 13, color: Color.dockWarning)
                                    .accessibilityHidden(true)
                                Text(blocker).textSelection(.enabled)
                            }
                        }
                        Link(destination: record.reference.webURL) {
                            HStack(spacing: 6) {
                                Text("View on GitHub")
                                DockIcon(.arrowSquareOut, size: 12, color: Color.dockSecondaryText)
                            }
                        }
                        .buttonStyle(.dockCompact)
                        .controlSize(.small)
                    }.foregroundStyle(Color.dockSecondaryText)
                }
            }
            if let result { Text(result).foregroundStyle(Color.dockSecondaryText) }
            if let error { Text(error).foregroundStyle(Color.dockWarning) }
        }.font(DockTypography.body).foregroundStyle(Color.dockPrimaryText).dockCard(padding: 12)
        .task(id: record.headRevision) { await load() }
        .confirmationDialog(pending?.rawValue ?? "Confirm GitHub action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil; confirmed = nil } }), titleVisibility: .visible) {
            Button(pending?.rawValue ?? "Confirm") {
                let action = pending; let original = confirmed; pending = nil; confirmed = nil
                if let action, let original { Task { await perform(action, original: original) } }
            }
            Button("Cancel", role: .cancel) { pending = nil; confirmed = nil }
        } message: { Text("\(record.reference.title) · \(record.title)\nHead: \(record.headRevision ?? "unknown")\n\(method.title)\nGitHub enforces repository rules. Queued and auto-merge requests may wait before merging.") }
    }
    private func actionButton(_ action: GitHubLandingAction, enabled: Bool) -> some View {
        Button(action.rawValue) { confirmed = snapshot; pending = action }.buttonStyle(.dockCompact).disabled(!enabled || busy)
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { snapshot = try await service.snapshot(record); if let first = snapshot?.methods.first, snapshot?.methods.contains(method) != true { method = first }; error = nil }
        catch { self.error = error.localizedDescription; snapshot = nil }
    }
    private func perform(_ action: GitHubLandingAction, original: GitHubLandingSnapshot) async {
        busy = true; result = "Requesting GitHub action…"; defer { busy = false }
        do {
            let updated = try await service.perform(action, method: method, record: record, confirmed: original)
            snapshot = updated; result = updated.status.isEmpty ? "Request accepted. Refreshing GitHub state…" : updated.status; error = nil; onChanged()
        } catch { result = nil; self.error = error.localizedDescription; onChanged() }
    }
}
