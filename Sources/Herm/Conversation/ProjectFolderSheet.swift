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
                DockSegmentedPicker(selection: $mode, options: Mode.allCases.map { ($0, $0.rawValue) })
            }
            if mode == .newProject {
                DockTextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            } else {
                DockMenuPicker("Project", title: target.map { URL(fileURLWithPath: $0.name).lastPathComponent } ?? "Choose…", selection: Binding(get: { target?.id ?? "" }, set: { targetID = $0 })) {
                    ForEach(projects) { DockMenuOption(URL(fileURLWithPath: $0.name).lastPathComponent, value: $0.id) }
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
        guard panel.runAboveHerm() == .OK, let url = panel.url else { return }
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

extension NSOpenPanel {
    /// Herm's windows are status-bar-level panels, so a default open panel
    /// opens underneath them. Match that level and order it in front.
    func runAboveHerm() -> NSApplication.ModalResponse {
        level = .statusBar
        hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        return runModal()
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

extension NSMenu {
    func addClosureItem(_ title: String, handler: @escaping () -> Void) {
        addItem(ClosureMenuItem(title, handler: handler))
    }
}
