import SwiftUI

struct PullRequestReviewerService {
    let client: GitHubClient

    func requested(_ reference: GitHubItemReference) async throws -> Set<String> {
        guard let row = try await client.request(path(reference)) as? [String: Any],
            let users = row["users"] as? [[String: Any]]
        else { throw GitHubRequestError.malformed }
        return Set(users.compactMap { $0["login"] as? String })
    }

    func choices(_ reference: GitHubItemReference, author: String) async throws -> [String] {
        let page = try await client.pages(reference.repository.apiRepositoryPath + "/collaborators")
        guard !page.coverage.partial else { throw GitHubRequestError.unavailable }
        return page.rows.compactMap { row in
            guard let login = row["login"] as? String,
                login.caseInsensitiveCompare(author) != .orderedSame,
                let permissions = row["permissions"] as? [String: Any],
                permissions["push"] as? Bool == true
            else { return nil }
            return login
        }.sorted()
    }

    func save(_ selected: Set<String>, original: Set<String>, reference: GitHubItemReference) async throws {
        let metadata = try await GitHubMetadataService(client: client).basic(reference)
        guard metadata.canUpdate || metadata.canTriage else { throw GitHubRequestError.forbidden }
        guard try await requested(reference) == original else { throw GitHubRequestError.changed }
        let adding = selected.subtracting(original)
        let removing = original.subtracting(selected)
        if !adding.isEmpty {
            _ = try await client.request(path(reference), method: "POST", body: ["reviewers": adding.sorted()])
        }
        if !removing.isEmpty {
            _ = try await client.request(path(reference), method: "DELETE", body: ["reviewers": removing.sorted()])
        }
    }

    private func path(_ reference: GitHubItemReference) -> String {
        reference.repository.apiRepositoryPath + "/pulls/\(reference.number)/requested_reviewers"
    }
}

struct PullRequestReviewerPicker: View {
    let record: PullRequestRecord
    let client: GitHubClient
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var choices: [String] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    private var service: PullRequestReviewerService { PullRequestReviewerService(client: client) }

    var body: some View {
        DockModal(title: "Select reviewers", subtitle: record.reference.title, width: 520) {
            TextField("Filter reviewers", text: $search).textFieldStyle(.dockGlass)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if busy && !loaded { ProgressView("Loading reviewers…") }
                    if loaded && choices.isEmpty {
                        Text("No eligible reviewers available.").foregroundStyle(Color.dockSecondaryText)
                    }
                    ForEach(
                        choices.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self
                    ) { login in
                        Toggle(
                            login,
                            isOn: Binding(
                                get: { selected.contains(login) },
                                set: { if $0 { selected.insert(login) } else { selected.remove(login) } })
                        ).toggleStyle(.dockSwitch)
                    }
                    if !loaded && !busy { Button("Retry") { Task { await load() } }.buttonStyle(.dockCompact) }
                }.frame(maxWidth: .infinity, alignment: .leading).disabled(busy)
            }.frame(minHeight: 120, maxHeight: 340)
            Text(error ?? " ").dockFont(.body).foregroundStyle(Color.dockWarning).frame(minHeight: 34)
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(.dockSecondary).disabled(busy)
            Spacer()
            Button {
                confirm = true
            } label: {
                GitHubActionLabel(title: busy ? "Saving…" : "Review changes", isBusy: busy)
            }
            .buttonStyle(.dockPrimary).disabled(!loaded || busy || selected == original)
        }
        .task { await load() }
        .interactiveDismissDisabled(busy)
        .confirmationDialog(
            "Update reviewers for \(record.reference.title)?", isPresented: $confirm, titleVisibility: .visible
        ) {
            Button("Save reviewers") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Request: \(selected.subtracting(original).sorted().joined(separator: ", "))\nRemove requests: \(original.subtracting(selected).sorted().joined(separator: ", "))"
            )
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            let metadata = try await GitHubMetadataService(client: client).basic(record.reference)
            guard metadata.canUpdate || metadata.canTriage else { throw GitHubRequestError.forbidden }
            original = try await service.requested(record.reference)
            choices = Array(Set(try await service.choices(record.reference, author: record.author)).union(original))
                .sorted()
            selected = original
            loaded = true
            error = nil
        } catch { self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await service.save(selected, original: original, reference: record.reference)
            onChanged()
            dismiss()
        } catch {
            self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
            // A partially successful write must be reloaded before another confirmation.
            loaded = false
            onChanged()
        }
    }
}
