import SwiftUI

/// Names a new Hermes Kanban board. Hermes owns the board; the sheet only
/// derives the slug Hermes requires and reports its answer.
struct KanbanBoardCreateSheet: View {
    @ObservedObject var control: ControlCenterModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var isCreating = false

    private var slug: String? { ControlCenterModel.kanbanBoardSlug(for: name) }

    var body: some View {
        DockModal(
            title: "New board", subtitle: "Boards are shared by every Hermes Agent profile.", width: 420
        ) {
            VStack(alignment: .leading, spacing: 10) {
                DockTextField("Board name", text: $name)
                    .textFieldStyle(.dockGlass)
                    .onSubmit(create)
                Text(slug.map { "Slug: \($0)" } ?? "Use at least one letter or number.")
                    .dockFont(.metadata, design: .monospaced)
                    .foregroundStyle(Color.dockSecondaryText)
                if let error {
                    Text(error)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.dockSecondary)
                Spacer()
                Button(isCreating ? "Creating…" : "Create board", action: create)
                    .buttonStyle(.dockPrimary)
                    .disabled(slug == nil || isCreating)
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private func create() {
        guard slug != nil, !isCreating else { return }
        isCreating = true
        error = nil
        let name = name
        Task {
            let failure = await control.createKanbanBoard(name: name)
            isCreating = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
