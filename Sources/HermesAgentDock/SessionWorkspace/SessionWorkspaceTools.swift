import SwiftUI

struct SessionFilesView: View {
    let projectPath: String?
    let onRefresh: () async -> Void
    @State private var entries: [ProjectFileEntry] = []
    @State private var expandedDirectories = Set<String>()
    @State private var document: RepositoryFileDocument?
    @State private var isLoading = false
    @State private var isOpeningFile = false
    @State private var error: String?
    @State private var filterText = ""
    @State private var selectedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document, let projectPath {
                RepositoryCodeWorkspaceView(
                    repositoryPath: projectPath,
                    document: document,
                    onClose: { self.document = nil },
                    onSave: { draft in
                        guard await RepositoryService.saveDocument(path: projectPath, filePath: document.path, contents: draft) else { return false }
                        await onRefresh()
                        self.document = RepositoryFileDocument(path: document.path, contents: draft, byteCount: draft.lengthOfBytes(using: .utf8))
                        return true
                    }
                )
            } else if projectPath != nil {
                explorer
            } else {
                empty("folder.badge.questionmark", "No project selected", "Choose a project before browsing its local files.")
            }
        }
        .task(id: projectPath) {
            guard let projectPath else { entries = []; return }
            isLoading = true
            selectedPath = nil
            let loadedEntries = await RepositoryService.projectFiles(path: projectPath)
            entries = loadedEntries
            // Show the complete project tree on first load. Users can still
            // collapse individual folders, but a newly opened project should
            // not look empty while its files are hidden behind collapsed rows.
            expandedDirectories = Set(loadedEntries.filter(\.isDirectory).map(\.path))
            isLoading = false
        }
        // Keep the files surface anchored to the inspector's top edge. Without
        // an explicit alignment, the empty state is centered inside the
        // full-height session inspector.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter files…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.dockCanvas)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.dockBorderLight, lineWidth: 0.5)
                }
                .padding(.bottom, 8)

            if isLoading {
                ProgressView("Loading files…")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if entries.isEmpty {
                empty("folder", "No readable files", "The selected project folder has no readable files.")
            } else {
                Button { } label: {
                    explorerRow(
                        icon: "folder.fill",
                        title: projectName,
                        path: nil,
                        depth: 0,
                        isDirectory: true,
                        isExpanded: true,
                        color: Color.dockFolder
                    )
                }
                .buttonStyle(.plain)
                .disabled(true)

                if let error {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.dockWarning)
                        .padding(.bottom, 6)
                }

                ForEach(visibleEntries) { entry in
                    if entry.isDirectory {
                        Button { toggle(entry.path) } label: {
                            explorerRow(
                                icon: expandedDirectories.contains(entry.path) ? "folder.fill" : "folder",
                                title: entryName(entry),
                                path: entry.path,
                                depth: entry.depth + 1,
                                isDirectory: true,
                                isExpanded: expandedDirectories.contains(entry.path),
                                color: Color.dockFolder
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { open(entry) } label: {
                            explorerRow(
                                icon: fileIcon(for: entry),
                                title: entryName(entry),
                                path: entry.path,
                                depth: entry.depth + 1,
                                isDirectory: false,
                                isExpanded: false,
                                color: fileColor(for: entry)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpeningFile)
                    }
                }

                if visibleEntries.isEmpty {
                    Text("No matching files")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .padding(.vertical, 12)
                }
            }
        }
        // The inspector already provides the scrolling container. Keep the
        // tree at its intrinsic height so collapsed rows cannot absorb the
        // remaining inspector height and appear hundreds of points apart.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func explorerRow(icon: String, title: String, path: String?, depth: Int, isDirectory: Bool, isExpanded: Bool, color: Color) -> some View {
        HStack(spacing: 8) {
            if isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }

            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isOpeningFile && selectedPath == path { ProgressView().controlSize(.mini) }
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        .background(selectedPath == path && !isDirectory ? Color.dockAccent.opacity(0.13) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var projectName: String {
        guard let projectPath else { return "HERMES-WORKSPACE" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    private var filterQuery: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var visibleEntries: [ProjectFileEntry] {
        let matchingPaths: Set<String>? = filterQuery.isEmpty ? nil : {
            var paths = Set<String>()
            for entry in entries where !entry.isDirectory && entry.path.lowercased().contains(filterQuery) {
                paths.insert(entry.path)
                let components = entry.path.split(separator: "/").map(String.init)
                for index in 0..<(max(0, components.count - 1)) {
                    paths.insert(components[...index].joined(separator: "/"))
                }
            }
            return paths
        }()

        return entries.filter { entry in
            if let matchingPaths { return matchingPaths.contains(entry.path) }
            let components = entry.path.split(separator: "/").map(String.init)
            guard components.count > 1 else { return true }
            let ancestorCount = entry.isDirectory ? components.count - 1 : components.count - 1
            for index in 0..<ancestorCount {
                let ancestor = components[...index].joined(separator: "/")
                if !expandedDirectories.contains(ancestor) { return false }
            }
            return true
        }
    }

    private func entryName(_ entry: ProjectFileEntry) -> String {
        entry.path.split(separator: "/").last.map(String.init) ?? entry.path
    }

    private func toggle(_ path: String) {
        if expandedDirectories.contains(path) { expandedDirectories.remove(path) }
        else { expandedDirectories.insert(path) }
    }

    private func open(_ entry: ProjectFileEntry) {
        guard let projectPath else { return }
        Task {
            isOpeningFile = true
            selectedPath = entry.path
            error = nil
            let loaded = await RepositoryService.loadDocument(path: projectPath, filePath: entry.path)
            isOpeningFile = false
            guard let loaded else {
                error = "This file cannot be opened inline. Only regular UTF-8 files up to 256 KB are supported."
                return
            }
            document = loaded
        }
    }

    private func fileIcon(for entry: ProjectFileEntry) -> String {
        switch entry.path.split(separator: ".").last.map(String.init)?.lowercased() {
        case "ts", "tsx", "js", "jsx", "swift", "py", "go", "rs": "curlybraces"
        case "json", "yaml", "yml", "toml": "doc.text"
        case "md", "txt": "doc.plaintext"
        default: "doc"
        }
    }

    private func fileColor(for entry: ProjectFileEntry) -> Color {
        switch entry.path.split(separator: ".").last.map(String.init)?.lowercased() {
        case "json", "yaml", "yml", "toml": return .dockWarning
        case "md", "txt": return .dockSecondaryText
        default: return .dockAccent
        }
    }

    private func empty(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockGlassPane()
    }
}

/// Real interactive terminal view following DESIGN.md glass pane & typography specifications.
struct SessionTerminalView: View {
    let projectPath: String?
    @StateObject private var terminal = LocalTerminalSession()
    @State private var command = ""
    @FocusState private var commandFocused: Bool

    private var statusColor: Color {
        switch terminal.state {
        case .running: Color.dockSuccess
        case .starting: Color.dockWarning
        case .closed, .idle: Color.dockSecondaryText
        case .failed: Color.dockDestructive
        }
    }

    private var statusText: String {
        switch terminal.state {
        case .running: "RUNNING"
        case .starting: "STARTING"
        case .closed: "CLOSED"
        case .idle: "IDLE"
        case .failed(let err): "FAILED (\(err))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            terminalTabBar
            HStack {
                Text("SHELL")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)
            }
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Scrollable Output Window
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminal.output.isEmpty ? "Terminal session initialized. Ready for commands." : terminal.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(terminal.output.isEmpty ? Color.dockSecondaryText : Color.dockPrimaryText)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 20)
                        .id("terminal-output")
                }
                .frame(minHeight: 260, maxHeight: .infinity)
                .background(Color.dockCanvas)
                .onChange(of: terminal.output) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("terminal-output", anchor: .bottom)
                    }
                }
            }

            // Command Prompt Input Bar
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dockSuccess)

                TextField("", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.dockPrimaryText)
                    .focused($commandFocused)
                    .onSubmit { submit() }
            }
            .padding(.vertical, 10)
            .background(Color.dockSurface2)
            .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
        }
        .background(Color.dockCanvas)
        .task(id: projectPath) {
            guard let projectPath else { terminal.close(); return }
            terminal.start(directory: projectPath)
            commandFocused = true
        }
        .onDisappear { terminal.close() }
    }

    private func submit() {
        guard !command.isEmpty else { return }
        terminal.send(command + "\n")
        command = ""
    }

    private var terminalTabBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
                Text("\(NSUserName())@\(Host.current().localizedName ?? "hermes")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Button {
                    terminal.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dockMetadataText)
                }
                .buttonStyle(.borderless)
                .help("Close terminal")
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.dockSurface6))

            Spacer(minLength: 0)

            Button {
                terminal.start(directory: projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path)
                commandFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("New terminal session")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }
}
