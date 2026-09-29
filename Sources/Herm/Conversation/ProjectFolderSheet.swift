import AppKit
import SwiftUI

/// Modal for the Projects header: create a project from a folder, or add a
/// source folder to an existing project. Folders are picked with NSOpenPanel.
struct ProjectFolderSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case newProject = "New project"
        case addFolder = "Add folder"
        var id: String { rawValue }
    }

    let projects: [ProjectSummary]
    let onCreate: (String, String) async -> Bool
    let onAddFolder: (ProjectSummary, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .newProject
    @State private var name = ""
    @State private var folder: URL?
    @State private var targetID: String?
    @State private var isWorking = false
    @State private var failed = false

    private var target: ProjectSummary? { projects.first { $0.id == targetID } ?? projects.first }
    private var canSubmit: Bool {
        guard folder != nil, !isWorking else { return false }
        return mode == .newProject ? !name.trimmingCharacters(in: .whitespaces).isEmpty : target != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Projects").font(.headline)
            if !projects.isEmpty {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if mode == .newProject {
                TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            } else {
                Picker("Project", selection: Binding(get: { target?.id ?? "" }, set: { targetID = $0 })) {
                    ForEach(projects) { Text(URL(fileURLWithPath: $0.name).lastPathComponent).tag($0.id) }
                }
            }
            HStack {
                Text(folder?.path ?? "No folder selected")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(folder == nil ? .secondary : .primary)
                Spacer()
                Button("Choose folder…", action: chooseFolder)
            }
            if failed { Text("Hermes could not save the change. Try again.").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .newProject ? "Create" : "Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.standardizedFileURL
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func submit() {
        guard let folder else { return }
        isWorking = true
        failed = false
        Task { @MainActor in
            let ok: Bool
            if mode == .newProject {
                ok = await onCreate(name.trimmingCharacters(in: .whitespaces), folder.path)
            } else if let target {
                ok = await onAddFolder(target, folder.path)
            } else { ok = false }
            isWorking = false
            if ok { dismiss() } else { failed = true }
        }
    }
}
