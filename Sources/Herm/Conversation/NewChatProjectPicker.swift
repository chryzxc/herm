import AppKit
import SwiftUI

/// Pure choice logic for the new-chat project picker, kept apart from the view so it can be tested.
enum NewChatProjectChoice {
    struct Option: Identifiable, Equatable {
        let id: String
        let path: String
        let title: String
    }

    /// Real projects only, in the order Hermes lists them, filtered by the search text.
    static func options(from projects: [ProjectSummary], query: String) -> [Option] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { $0.isRenderableProject && $0.name.hasPrefix("/") }.compactMap { project -> Option? in
            let title = SessionNavSidebarSnapshot.projectDisplayName(project.name)
            guard
                search.isEmpty || title.localizedCaseInsensitiveContains(search)
                    || project.name.localizedCaseInsensitiveContains(search)
            else { return nil }
            return Option(id: project.id, path: project.name, title: title)
        }
    }

    /// The label for the bar: the chosen project's name, or the prompt to choose one.
    static func label(forPath path: String?) -> String {
        guard let path, !path.isEmpty else { return "Choose project" }
        return SessionNavSidebarSnapshot.projectDisplayName(path)
    }

    static func isSelected(_ option: Option, path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return URL(fileURLWithPath: option.path).standardizedFileURL.path
            == URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// The bar above a new chat's input that picks the Herm project the chat starts in.
struct NewChatProjectPicker: View {
    let projects: [ProjectSummary]
    let selectedPath: String?
    let canCreateProject: Bool
    let onSelect: (String) -> Void
    /// Creates a project from a folder; returns the folder path to select when it succeeded.
    let onCreate: (String) async -> Bool

    @State private var isOpen = false
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    DockIcon(.folder)
                    Text(NewChatProjectChoice.label(forPath: selectedPath))
                        .lineLimit(1).truncationMode(.middle)
                }
                .dockFont(.metadata)
                .foregroundStyle(selectedPath == nil ? Color.dockMetadataText : Color.dockSecondaryText)
                .dockPadding(.horizontal, 6)
                .frame(height: 24)
            }
            .buttonStyle(.dockHover)
            .help(selectedPath ?? "Choose the project this chat belongs to")
            .accessibilityLabel("Choose project")
            .accessibilityValue(NewChatProjectChoice.label(forPath: selectedPath))
            .dockPopover(isPresented: $isOpen, attachmentAnchor: .point(.topLeading), arrowEdge: .top) {
                panel
            }
            Spacer(minLength: 0)
        }
        .dockPadding(.horizontal, 8)
        .dockPadding(.vertical, 2)
        .frame(height: 28)
    }

    private var panel: some View {
        let options = NewChatProjectChoice.options(from: projects, query: query)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DockIcon(.magnifyingGlass, size: 12, color: .dockMetadataText)
                DockTextField("Search projects", text: $query)
                    .textFieldStyle(.plain)
            }
            .dockPadding(.horizontal, 12)
            .frame(height: 36)
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if options.isEmpty {
                        Text(query.isEmpty ? "No projects yet" : "No matching projects")
                            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                            .dockPadding(.horizontal, 8).dockPadding(.vertical, 10)
                    }
                    ForEach(options) { option in
                        Button {
                            onSelect(option.path)
                            close()
                        } label: {
                            HStack(spacing: 8) {
                                DockIcon(.folder, size: 12, color: .dockSecondaryText).frame(width: 16)
                                Text(option.title).dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if NewChatProjectChoice.isSelected(option, path: selectedPath) {
                                    DockIcon(.check, size: 12, color: .dockSecondaryText)
                                }
                            }
                            .dockPadding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .help(option.path)
                    }
                }
                .dockPadding(.horizontal, 6)
                .dockPadding(.vertical, 5)
            }
            .frame(maxHeight: 240)
            if canCreateProject {
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                Button {
                    close()
                    DispatchQueue.main.async { createProject() }
                } label: {
                    HStack(spacing: 8) {
                        DockIcon(.plus, size: 12, color: .dockSecondaryText).frame(width: 16)
                        Text("New project").dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                        Spacer(minLength: 0)
                    }
                    .dockPadding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .dockPadding(.horizontal, 6)
                .dockPadding(.vertical, 5)
                .help("Create a Herm project from a folder")
            }
        }
        .frame(width: 260)
    }

    private func close() {
        isOpen = false
        query = ""
    }

    private func createProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.message = "Select the folder to add as a Herm project."
        panel.prompt = "Create Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runAboveHerm() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        Task { @MainActor in
            if await onCreate(path) { onSelect(path) }
        }
    }
}
