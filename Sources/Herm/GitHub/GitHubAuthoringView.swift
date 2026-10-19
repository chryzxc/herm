import SwiftUI

struct GitHubAuthoringService: Sendable {
    let client: GitHubClient
    func save(kind: GitHubItemKind, repository: GitHubRepositoryReference, reference: GitHubItemReference?, original: GitHubMetadataSnapshot?, title: String, body: String, head: String = "", base: String = "") async throws -> GitHubItemReference {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200, body.count <= 10_000, !title.contains("\n"), !title.contains("\0"), !body.contains("\0") else { throw GitHubRequestError.malformed }
        if let reference {
            let fresh = try await GitHubMetadataService(client: client).basic(reference)
            guard fresh.canUpdate else { throw GitHubRequestError.forbidden }
            guard fresh.updatedAt == original?.updatedAt, fresh.title == original?.title, fresh.body == original?.body else { throw GitHubRequestError.changed }
        }
        if kind == .pullRequest {
            let mutation: GitHubPullRequestMutation
            let built = reference.map { GitHubPullRequestMutationBuilder.update(repository: repository, number: $0.number, title: title, body: body) } ?? GitHubPullRequestMutationBuilder.createDraft(repository: repository, title: title, body: body, headBranch: head, baseBranch: base)
            guard case .success(let valid) = built else { throw GitHubRequestError.malformed }; mutation = valid
            if reference == nil, head == base { throw GitHubRequestError.malformed }
            let service = GitHubCodeHostService(client: client)
            let result = reference == nil ? await service.createDraftPullRequest(mutation) : await service.updatePullRequest(mutation)
            guard case .success(let pr) = result else { throw GitHubRequestError.unavailable }
            return GitHubItemReference(repository: repository, number: pr.number, kind: kind)
        }
        let path = reference?.issuePath ?? repository.apiRepositoryPath + "/issues"
        guard let row = try await client.request(path, method: reference == nil ? "POST" : "PATCH", body: ["title": title, "body": body]) as? [String: Any], let number = row["number"] as? Int else { throw GitHubRequestError.malformed }
        return GitHubItemReference(repository: repository, number: number, kind: kind, nodeID: row["node_id"] as? String)
    }
    func setIssueState(_ reference: GitHubItemReference, state: String, reason: String? = nil) async throws -> GitHubIssueRecord {
        guard reference.kind == .issue, ["open", "closed"].contains(state) else { throw GitHubRequestError.malformed }
        let metadata = try await GitHubMetadataService(client: client).basic(reference)
        guard metadata.canUpdate || metadata.canTriage else { throw GitHubRequestError.forbidden }
        var body = ["state": state]
        if let reason { body["state_reason"] = reason }
        guard var payload = try await client.request(reference.issuePath, method: "PATCH", body: body) as? [String: Any] else { throw GitHubRequestError.malformed }
        payload["repository_url"] = "https://api.github.com" + reference.repository.apiRepositoryPath
        guard let result = GitHubIssueParser.parse(payload), result.number == reference.number else { throw GitHubRequestError.malformed }
        return result
    }
}

struct GitHubAuthoringMenu: View {
    let reference: GitHubItemReference
    let client: GitHubClient
    var onIssueStateChanged: ((GitHubIssueRecord) -> Void)? = nil
    let onChanged: () -> Void
    @State private var loading = false
    @State private var metadata: GitHubMetadataSnapshot?
    @State private var state = ""
    @State private var editing = false
    @State private var pendingState: String?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        DockMenu {
            if metadata == nil { Button("Retry loading actions") { Task { await load() } } }
            Button("Edit title and description") { editing = true }.disabled(metadata?.canUpdate != true || busy)
            if reference.kind == .issue {
                Button("Close as completed") { pendingState = "completed" }.disabled(state != "open" || busy || !canManage)
                Button("Close as not planned") { pendingState = "not_planned" }.disabled(state != "open" || busy || !canManage)
                Button("Reopen issue") { pendingState = "open" }.disabled(state != "closed" || busy || !canManage)
            }
            Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reference.webURL.absoluteString, forType: .string) }
            Link("Open on GitHub", destination: reference.webURL)
        } label: {
            Group {
                if busy || loading { ProgressView().controlSize(.mini) }
                else { DockIcon(.dotsThree, size: 14, color: Color.dockSecondaryText) }
            }.frame(width: 28, height: 28)
                .background(Color.dockControlSurface.opacity(0.6), in: DockThemeShape(cornerRadius: DockLayout.controlRadius - 1))
        }
        .disabled(busy || loading)
        .help("GitHub item actions").accessibilityLabel(busy ? "Updating issue…" : (loading ? "Loading item actions…" : "GitHub item actions"))
        .task(id: reference.id) { await load() }
        .sheet(isPresented: $editing) { GitHubItemEditor(kind: reference.kind, client: client, reference: reference) { _ in Task { await load() }; onChanged() } }
        .confirmationDialog("Change issue \(reference.title)?", isPresented: Binding(get: { pendingState != nil }, set: { if !$0 { pendingState = nil } }), titleVisibility: .visible, presenting: pendingState) { requested in
            Button(requested == "open" ? "Reopen issue" : "Close issue") {
                pendingState = nil
                Task {
                    busy = true; defer { busy = false }
                    do {
                        let updated = try await GitHubAuthoringService(client: client).setIssueState(reference, state: requested == "open" ? "open" : "closed", reason: requested == "open" ? nil : requested)
                        state = updated.state; error = nil
                        if let onIssueStateChanged { onIssueStateChanged(updated) } else { onChanged() }
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { pendingState = nil }
        } message: { requested in Text(requested == "open" ? "Reopen this issue on GitHub." : "Close this issue as \(requested.replacingOccurrences(of: "_", with: " ")).") }
        .alert("GitHub change failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private var canManage: Bool { metadata?.canUpdate == true || metadata?.canTriage == true }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            metadata = try await GitHubMetadataService(client: client).basic(reference)
            if let row = try await client.request(reference.issuePath) as? [String: Any] { state = row["state"] as? String ?? "" }
        } catch { metadata = nil }
    }
}

struct GitHubItemEditor: View {
    let kind: GitHubItemKind
    let client: GitHubClient
    var reference: GitHubItemReference? = nil
    var repositories: [GitHubRepositoryReference] = []
    var initialRepository: GitHubRepositoryReference? = nil
    let onSaved: (GitHubItemReference) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryName = ""
    @State private var title = ""
    @State private var text = ""
    @State private var head = ""
    @State private var base = ""
    @State private var branches: [String] = []
    @State private var loadingBranches = false
    @State private var branchLoadID = UUID()
    @State private var original: GitHubMetadataSnapshot?
    @State private var preview = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    @State private var ready = false
    private var repository: GitHubRepositoryReference? { reference?.repository ?? GitHubReferenceParser.repository(repositoryName) }
    private var action: String { reference != nil ? "Save changes" : (kind == .issue ? "Create issue" : "Create draft PR") }
    private var valid: Bool { ready && !loadingBranches && repository != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 200 && text.count <= 10_000 && (kind == .issue || reference != nil || (!head.isEmpty && !base.isEmpty && head != base)) }
    var body: some View {
        DockModal(title: reference == nil ? (kind == .issue ? "New issue" : "New draft pull request") : "Edit title and description", subtitle: reference?.title ?? "Review before publishing to GitHub", width: 600) {
            if reference == nil {
                HStack {
                    TextField("owner/repo", text: $repositoryName).textFieldStyle(.dockGlass)
                    if !repositories.isEmpty { Menu("Repositories") { ForEach(repositories) { repo in Button(repo.id) { repositoryName = repo.id } } } }
                }
                if kind == .pullRequest {
                    HStack {
                        if loadingBranches { ProgressView().controlSize(.mini).accessibilityLabel("Loading branches") }
                        Picker("Head branch", selection: $head) { Text("Choose branch").tag(""); ForEach(branches, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                        Picker("Base branch", selection: $base) { Text("Choose branch").tag(""); ForEach(branches, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                    }.disabled(loadingBranches || busy)
                    Text("Only published branches are listed. Creating a PR never pushes local changes.").font(DockTypography.body).foregroundStyle(Color.dockSecondaryText)
                }
            }
            TextField("Title", text: $title).textFieldStyle(.dockGlass)
            HStack {
                DockTabButton(title: "Write", isSelected: !preview) { preview = false }
                DockTabButton(title: "Preview", isSelected: preview) { preview = true }
                Spacer(); Text("\(text.count)/10000").font(DockTypography.metadata).foregroundStyle(text.count > 10_000 ? Color.dockWarning : Color.dockMetadataText)
            }
            Group {
                if preview { ScrollView { MarkdownMessageView(markdown: text.isEmpty ? "No description provided." : text).frame(maxWidth: .infinity, alignment: .leading) } }
                else { TextEditor(text: $text).font(DockTypography.body).scrollContentBackground(.hidden).padding(8).background(Color.dockControlSurface, in: DockThemeShape(cornerRadius: DockLayout.controlRadius)) }
            }.frame(height: 260)
            Text(error ?? " ").font(DockTypography.body).foregroundStyle(Color.dockWarning).frame(minHeight: 34, alignment: .topLeading)
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(.dockSecondary).disabled(busy)
            Spacer()
            Button { confirm = true } label: { GitHubActionLabel(title: busy ? (ready ? "Saving…" : "Loading…") : action, isBusy: busy) }.buttonStyle(.dockPrimary).disabled(busy || !valid)
        }
        .interactiveDismissDisabled(busy)
        .task {
            repositoryName = reference?.repository.id ?? initialRepository?.id ?? repositories.first?.id ?? ""
            if let reference {
                busy = true; defer { busy = false }
                do { let data = try await GitHubMetadataService(client: client).basic(reference); guard data.canUpdate else { throw GitHubRequestError.forbidden }; original = data; title = data.title; text = data.body; ready = true }
                catch { self.error = error.localizedDescription }
            } else { ready = true }
        }
        .task(id: repositoryName) { await loadBranches() }
        .confirmationDialog("\(action) on \(repository?.id ?? "GitHub")?", isPresented: $confirm, titleVisibility: .visible) {
            Button(action) { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("\(title)\n\(kind == .pullRequest && reference == nil ? head + " → " + base + "\nDraft pull request\n" : "")\n\(text)") }
    }
    private func loadBranches() async {
        guard kind == .pullRequest, reference == nil, let repository else { return }
        let token = UUID(); branchLoadID = token
        loadingBranches = true; branches = []; head = ""; base = ""
        defer { if token == branchLoadID { loadingBranches = false } }
        do {
            try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation()
            let page = try await client.pages(repository.apiRepositoryPath + "/branches")
            try Task.checkCancellation()
            guard !page.coverage.partial else { throw GitHubRequestError.unavailable }
            branches = page.rows.compactMap { $0["name"] as? String }
            if let row = try await client.request(repository.apiRepositoryPath) as? [String: Any] {
                try Task.checkCancellation()
                guard token == branchLoadID else { return }
                base = row["default_branch"] as? String ?? ""
            }
            if !branches.contains(head) { head = "" }; error = nil
        } catch is CancellationError {} catch { if !Task.isCancelled { branches = []; self.error = error.localizedDescription } }
    }
    private func save() async {
        guard valid, let repository, !busy else { return }; busy = true; defer { busy = false }
        do {
            let result = try await GitHubAuthoringService(client: client).save(kind: kind, repository: repository, reference: reference, original: original, title: title, body: text, head: head, base: base)
            onSaved(result); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
