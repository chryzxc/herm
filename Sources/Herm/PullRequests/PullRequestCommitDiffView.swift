import SwiftUI

struct PullRequestCommitDiffView: View {
    let target: PullRequestCommitDiffTarget
    let client: GitHubClient
    var commitCheckEvidence: DockCommitCheckEvidence? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var result: GitHubPage<PullRequestFile>?
    @State private var selectedPath: String?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        DockExpandedPage(
            title: "Commit",
            subtitle: target.repository.id + " · " + target.commit.message,
            close: { dismiss() },
            trailing: {
                DockCommitIdentifier(
                    revision: target.commit.id, repositoryID: target.repository.id, evidence: commitCheckEvidence)
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if let result {
                    if let notice = result.coverage.label {
                        Text(HermesDiagnosticsService.safeSummary(notice))
                            .dockFont(.metadata).foregroundStyle(Color.dockWarning).dockPadding(12)
                    }
                    if result.items.isEmpty {
                        status("No changed files in this commit.")
                    } else {
                        filePicker(result.items)
                        if let file = result.items.first(where: { $0.path == selectedPath }) {
                            if let patch = file.patch, !patch.isEmpty {
                                SharedDiffView(patch: patch, path: file.path)
                                    .id(target.id + ":" + file.path)
                            } else {
                                status("Patch unavailable for this file. It may be binary or too large.")
                            }
                        }
                    }
                } else if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        Button("Retry") { attempt += 1 }.buttonStyle(.dockSecondary)
                    }.dockPadding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ProgressView("Loading commit diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: attempt) { await load() }
    }

    private func filePicker(_ files: [PullRequestFile]) -> some View {
        HStack(spacing: 12) {
            DockOptionPicker(selection: $selectedPath, options: files.map { (Optional($0.path), $0.path) })
                .accessibilityLabel("Changed file")
            if let file = files.first(where: { $0.path == selectedPath }) {
                Text("+\(file.additions)").foregroundStyle(Color.dockSuccess)
                Text("−\(file.deletions)").foregroundStyle(Color.dockDestructive)
            }
            if let url = target.commit.webURL {
                Link("GitHub", destination: url).buttonStyle(.dockLink)
            }
        }.dockFont(.body).dockPadding(12)
    }

    private func status(_ message: String) -> some View {
        Text(message).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            .dockPadding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func load() async {
        error = nil
        do {
            let loaded = try await PullRequestCommitDiffService(client: client).load(
                repository: target.repository, sha: target.commit.id)
            try Task.checkCancellation()
            selectedPath = loaded.items.first?.path
            result = loaded
        } catch {
            guard !Task.isCancelled else { return }
            self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }
}
