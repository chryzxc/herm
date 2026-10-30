import AppKit
import SwiftUI

/// Modal for the Projects header: create a project with an optional source folder,
/// picked with NSOpenPanel or dropped onto the folder card.
struct ProjectFolderSheet: View {
    let onCreate: (String, String?) async -> Bool
    var failureReason: () -> String? = { nil }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?
    @State private var isWorking = false
    @State private var isDropTargeted = false
    @State private var failure: String?

    private var canSubmit: Bool {
        !isWorking && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        DockModal(
            icon: .folderPlus, title: "New Project",
            subtitle: "Name your project and optionally choose a source folder.",
            width: 440
        ) {
            labeledField("Name") { DockTextField("Project name", text: $name).textFieldStyle(.dockGlass) }
            labeledField("Source folder (optional)") { folderCard }
            if let failure { ModalNote(text: failure, icon: .warning, tone: .dockDestructive) }
        } footer: {
            modalActions(
                primaryTitle: "Create", pendingTitle: "Creating…", isDisabled: !canSubmit, isPending: isWorking,
                onCancel: { dismiss() }, onPrimary: submit)
        }
    }

    private var folderCard: some View {
        Group {
            if let folder {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").dockFont(size: 17).foregroundStyle(Color.dockAccent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.lastPathComponent).dockFont(.body, weight: .medium).foregroundStyle(
                            Color.dockPrimaryText)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(1).truncationMode(
                                .middle)
                    }
                    Spacer(minLength: 8)
                    Button("Change…", action: chooseFolder).buttonStyle(.dockSecondary).controlSize(.small)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line").dockFont(size: 17).foregroundStyle(
                        isDropTargeted ? Color.dockAccent : Color.dockMetadataText)
                    Text("Drop a folder here").dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                    Button("Choose…", action: chooseFolder).buttonStyle(.dockSecondary).controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .dockPadding(14)
        .frame(minHeight: folder == nil ? 110 : 60)
        .background(isDropTargeted ? Color.dockAccentMuted : Color.dockSurface4, in: DockThemeShape(cornerRadius: 10))
        .overlay(
            DockThemeShape(cornerRadius: 10)
                .stroke(
                    isDropTargeted ? Color.dockAccent : Color.dockBorder,
                    style: StrokeStyle(lineWidth: 1, dash: folder == nil ? [5, 4] : []))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard
                let url = urls.first(where: {
                    $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                })
            else { return false }
            setFolder(url)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    private func setFolder(_ url: URL) {
        folder = url.standardizedFileURL
        failure = nil
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a source folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runAboveHerm() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        failure = nil
        Task { @MainActor in
            let ok = await onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), folder?.path)
            isWorking = false
            if ok { dismiss() } else { failure = failureReason() ?? "Hermes could not save the change. Try again." }
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
