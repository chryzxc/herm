import SwiftUI

struct RepositoryStashSection: View {
    @ObservedObject var workflow: DeveloperWorkflowModel
    let actionsDisabled: Bool
    let perform: (RepositorySourceControlAction) -> Void

    @State private var isExpanded = true
    @State private var showingCreate = false
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var selectedStash: RepositoryStash?
    @State private var operation = RepositoryStashOperation.apply
    @State private var showingConfirmation = false

    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockSectionHeader(
                title: "Stash", count: workflow.stashes.count, isExpanded: $isExpanded, style: style, icon: .archive,
                tint: .dockSecondaryText
            ) {
                DockIconButton(
                    icon: .plus, label: "Stash changes", isBusy: workflow.isMutatingSourceControl, size: 22,
                    style: style
                ) {
                    showingCreate = true
                }
                .disabled(
                    actionsDisabled || workflow.changes?.files.isEmpty != false
                        || (workflow.changes?.conflictedCount ?? 0) > 0
                )
                .popover(isPresented: $showingCreate, arrowEdge: .bottom) { createPopover }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = workflow.stashesError {
                        Text(error).dockFont(.body).foregroundStyle(Color.dockWarning).padding(8)
                    } else if workflow.stashes.isEmpty {
                        Text(workflow.isRefreshing ? "Loading stashes…" : "No stashes")
                            .dockFont(.body).foregroundStyle(Color.dockMetadataText).padding(8)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(workflow.stashes) { stash in
                                RepositoryStashRow(
                                    path: workflow.repository.path, stash: stash, actionsDisabled: actionsDisabled
                                ) { requestedOperation in
                                    selectedStash = stash
                                    operation = requestedOperation
                                    showingConfirmation = true
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(.top, 12)
        .confirmationDialog(
            "\(operation.rawValue) stash?", isPresented: $showingConfirmation, titleVisibility: .visible
        ) {
            Button("\(operation.rawValue) Stash", role: operation == .drop ? .destructive : nil) {
                if let selectedStash { perform(.updateStash(selectedStash, operation)) }
                selectedStash = nil
            }
            Button("Cancel", role: .cancel) { selectedStash = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        let subject = selectedStash?.subject ?? ""
        switch operation {
        case .apply:
            return
                "Restore “\(subject)” into the selected worktree, including its staged state. The stash will be kept."
        case .pop:
            return
                "Restore “\(subject)” into the selected worktree, including its staged state, then delete the stash if restoration succeeds. Conflicts keep the stash."
        case .drop:
            return "Permanently delete “\(subject)” from this repository’s stash list. This cannot be undone in Herm."
        }
    }

    private var createPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save changes from the selected worktree and reset those files to HEAD.")
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            TextField("Stash message (optional)", text: $message)
                .textFieldStyle(.dockGlass).dockFont(.body)
            Toggle("Include untracked files", isOn: $includeUntracked)
                .dockFont(.body)
            Text("Ignored files stay in the worktree. Stashes are shared across this repository’s worktrees.")
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            Button("Create Stash") {
                perform(.createStash(message: message, includeUntracked: includeUntracked))
                showingCreate = false
            }
            .buttonStyle(.dockPrimary)
            .disabled(actionsDisabled)
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct RepositoryStashRow: View {
    let path: String
    let stash: RepositoryStash
    let actionsDisabled: Bool
    let requestOperation: (RepositoryStashOperation) -> Void

    @State private var isExpanded = false
    @State private var patch: String?
    @State private var isTruncated = false
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    DockIcon(isExpanded ? .caretDown : .caretRight, size: 11, color: .dockMetadataText)
                    Text(stash.reference).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    Text(stash.subject).dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 30).contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("\(stash.subject) · \(stash.date.formatted())")
            .accessibilityLabel(
                "\(stash.reference), \(stash.subject). \(isExpanded ? "Collapse" : "Show") stash changes"
            )
            .contextMenu {
                Button("Apply Stash") { requestOperation(.apply) }.disabled(actionsDisabled)
                Button("Pop Stash") { requestOperation(.pop) }.disabled(actionsDisabled)
                Button("Delete Stash…", role: .destructive) { requestOperation(.drop) }.disabled(actionsDisabled)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Apply") { requestOperation(.apply) }.buttonStyle(.dockCompact)
                        Button("Pop") { requestOperation(.pop) }.buttonStyle(.dockCompact)
                        Button("Delete…", role: .destructive) { requestOperation(.drop) }.buttonStyle(.dockCompact)
                    }
                    .disabled(actionsDisabled)
                    Text(stash.date.formatted()).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if let patch {
                        if patch.isEmpty {
                            Text("No textual changes in this stash.").dockFont(.body).foregroundStyle(
                                Color.dockMetadataText)
                        } else {
                            SharedDiffView(patch: patch, path: stash.reference)
                                .frame(maxHeight: 360)
                        }
                        if isTruncated {
                            Text("Diff truncated for safe display.").dockFont(.metadata).foregroundStyle(
                                Color.dockWarning)
                        }
                    } else {
                        Text("Stash changes are unavailable.").dockFont(.body).foregroundStyle(Color.dockWarning)
                    }
                }
                .padding(8)
            }
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            isLoading = true
            let result = await RepositoryService.stashDiff(path: path, stash: stash)
            guard !Task.isCancelled else { return }
            patch = result?.text
            isTruncated = result?.isTruncated ?? false
            isLoading = false
        }
    }
}
