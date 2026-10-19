import SwiftUI

struct GitHubBranchDeletionTarget: Equatable, Sendable {
    let refID: String
    let repositoryID: String
    let repository: String
    let name: String
    let revision: String
}
struct GitHubBranchCleanupSnapshot: Equatable, Sendable {
    let target: GitHubBranchDeletionTarget?
    let message: String
}
struct GitHubBranchCleanupService: Sendable {
    let client: GitHubClient
    func snapshot(_ record: PullRequestRecord) async throws -> GitHubBranchCleanupSnapshot {
        guard record.mergedAt != nil, let id = record.nodeID, let revision = record.headRevision else { throw GitHubRequestError.changed }
        let data = try await client.graphQL("query($id:ID!){node(id:$id){... on PullRequest{id state headRefOid viewerCanDeleteHeadRef headRef{id name prefix target{oid} branchProtectionRule{id} repository{id nameWithOwner defaultBranchRef{id}}}}}}", variables: ["id": id])
        guard let row = data["node"] as? [String: Any], row["id"] as? String == id,
              row["state"] as? String == "MERGED", row["headRefOid"] as? String == revision,
              row.keys.contains("headRef") else { throw GitHubRequestError.changed }
        if row["headRef"] is NSNull { return .init(target: nil, message: "Remote branch already deleted.") }
        guard let ref = row["headRef"] as? [String: Any], let refID = ref["id"] as? String,
              let name = ref["name"] as? String, ref["prefix"] as? String == "refs/heads/",
              let repo = ref["repository"] as? [String: Any], let repoID = repo["id"] as? String,
              let fullName = repo["nameWithOwner"] as? String,
              let defaultRef = repo["defaultBranchRef"] as? [String: Any], let defaultID = defaultRef["id"] as? String,
              let target = ref["target"] as? [String: Any], let oid = target["oid"] as? String else { throw GitHubRequestError.malformed }
        if refID == defaultID || ref["branchProtectionRule"] is [String: Any] {
            return .init(target: nil, message: "Branch “\(name)” is protected or is the default branch; it was kept.")
        }
        if oid != revision { return .init(target: nil, message: "Branch “\(name)” changed after this PR; it was kept.") }
        guard row["viewerCanDeleteHeadRef"] as? Bool == true else {
            return .init(target: nil, message: "Remote branch “\(name)” remains on GitHub. You do not have permission to delete it.")
        }
        return .init(target: .init(refID: refID, repositoryID: repoID, repository: fullName, name: name, revision: oid), message: "Remote branch: \(fullName):\(name)")
    }
    func delete(_ target: GitHubBranchDeletionTarget, for record: PullRequestRecord) async throws {
        let fresh = try await snapshot(record)
        guard fresh.target == target else { throw GitHubRequestError.changed }
        // Compare-and-delete prevents a concurrent push from losing new commits.
        _ = try await client.graphQL("mutation($input:UpdateRefsInput!){updateRefs(input:$input){clientMutationId}}", variables: ["input": ["repositoryId": target.repositoryID, "refUpdates": [["name": "refs/heads/" + target.name, "beforeOid": target.revision, "afterOid": String(repeating: "0", count: 40), "force": false]]]])
    }
}

struct GitHubBranchCleanupView: View {
    let record: PullRequestRecord
    let client: GitHubClient
    @State private var snapshot: GitHubBranchCleanupSnapshot?
    @State private var loading = false
    @State private var deleting = false
    @State private var pending: GitHubBranchDeletionTarget?
    @State private var error: String?
    private var service: GitHubBranchCleanupService { .init(client: client) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot?.message ?? (loading ? "Checking remote branch…" : "Remote branch details unavailable.")).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                if let target = snapshot?.target {
                    Button { pending = target } label: { GitHubActionLabel(title: deleting ? "Deleting…" : "Delete branch", isBusy: deleting) }
                        .buttonStyle(.dockCompact).fixedSize().disabled(loading || deleting)
                }
                DockIconButton(icon: .arrowsClockwise, label: "Refresh remote branch", isBusy: loading || deleting, size: 24, style: DockThemePalette(theme: DockThemeRuntime.current)) { Task { await load() } }
                Spacer(minLength: 0)
                }
            }
            if let error { Text(error).foregroundStyle(Color.dockWarning) }
        }
        .task(id: record.headRevision) { await load() }
        .confirmationDialog("Delete remote branch?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { target in
            Button("Delete branch", role: .destructive) {
                pending = nil
                Task {
                    guard !deleting else { return }; deleting = true; defer { deleting = false }
                    do {
                        try await service.delete(target, for: record)
                        snapshot = .init(target: nil, message: "Remote branch “\(target.name)” deleted."); error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { target in Text("Delete \(target.repository):\(target.name) at \(target.revision.prefix(7)) after merging \(record.reference.title)? Local branches and worktrees are unchanged.") }
    }
    private func load() async {
        guard !loading, !deleting else { return }; loading = true; defer { loading = false }
        do { let updated = try await service.snapshot(record); try Task.checkCancellation(); snapshot = updated; error = nil }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
