import SwiftUI

struct ProjectActionsEditor: View {
    let path: String
    @ObservedObject var preferences: ProjectPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var actions: [ProjectAction] = []
    @State private var error: String?
    var body: some View {
        DockModal(
            title: "Project actions", subtitle: "Commands run only when you choose Run. Output stays in the terminal.",
            width: nil
        ) {
            Text(path).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
            ScrollView {
                ForEach($actions) { $action in
                    VStack(alignment: .leading, spacing: 8) {
                        labeledField("Name") { TextField("Action name", text: $action.name).textFieldStyle(.dockGlass) }
                        labeledField("Command") {
                            TextField("Command to run", text: $action.command).textFieldStyle(.dockGlass)
                        }
                        labeledField("Working directory", hint: "Relative to project") {
                            HStack {
                                TextField("Directory", text: $action.directory).textFieldStyle(.dockGlass)
                                Button("Remove") { actions.removeAll { $0.id == action.id } }.buttonStyle(.dockCompact)
                            }
                        }
                        Toggle(
                            "Offer as worktree setup",
                            isOn: Binding(get: { action.isSetup == true }, set: { action.isSetup = $0 })
                        ).toggleStyle(.checkbox)
                        Divider().overlay(Color.dockBorderLight)
                    }.padding(.vertical, 8)
                }
            }
            if let error { Text(error).dockFont(.body).foregroundStyle(Color.dockWarning) }
        } footer: {
            Button("Add action") { actions.append(ProjectAction(name: "", command: "")) }.buttonStyle(
                .dockSecondary)
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.dockSecondary)
            Button("Save") {
                do {
                    for action in actions { _ = try action.workingDirectory(project: path) }
                    try preferences.save(actions, path: path)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.dockPrimary)
        }.dockFont(.body).foregroundStyle(Color.dockPrimaryText).frame(width: 560, height: 500).onAppear {
            actions = preferences.actions(path)
        }
    }
}
