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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let document {
                RepositoryCodeWorkspaceView(
                    document: document,
                    diff: nil,
                    isLoadingDiff: false,
                    onClose: { self.document = nil },
                    onReloadDiff: {},
                    onSave: { draft in
                        guard let projectPath else { return false }
                        guard await RepositoryService.saveDocument(path: projectPath, filePath: document.path, contents: draft) else { return false }
                        await onRefresh()
                        self.document = RepositoryFileDocument(path: document.path, contents: draft, byteCount: draft.lengthOfBytes(using: .utf8))
                        return true
                    }
                )
            } else if projectPath != nil {
                if isLoading { ProgressView("Loading project files…").font(.system(size: 12)) }
                else if entries.isEmpty { empty("folder", "No readable files", "The selected project folder has no readable files.") }
                else {
                    Text("\(entries.count) files\(entries.count == RepositoryService.maxProjectExplorerEntries ? "+" : "")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.scifiTertiary)
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.scifiWarning) }
                    ForEach(visibleEntries) { entry in
                        if entry.isDirectory {
                            Button { toggle(entry.path) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: expandedDirectories.contains(entry.path) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                    Image(systemName: expandedDirectories.contains(entry.path) ? "folder.fill" : "folder")
                                    Text(entryName(entry)).lineLimit(1)
                                    Spacer()
                                }
                                .foregroundStyle(Color.scifiTertiary)
                                .padding(.leading, CGFloat(entry.depth) * 12)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            }
                            .buttonStyle(.scifiPress)
                        } else {
                            Button { open(entry) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "doc")
                                    Text(entryName(entry)).lineLimit(1)
                                    Spacer()
                                    if isOpeningFile { ProgressView().controlSize(.mini) }
                                }
                                .foregroundStyle(Color.scifiFg)
                                .padding(.leading, CGFloat(entry.depth) * 12 + 15)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            }
                            .buttonStyle(.scifiPress)
                            .disabled(isOpeningFile)
                        }
                    }
                }
            } else {
                empty("folder.badge.questionmark", "No project selected", "Choose a project before browsing its local files.")
            }
        }
        .task(id: projectPath) {
            guard let projectPath else { entries = []; return }
            isLoading = true
            expandedDirectories = []
            entries = await RepositoryService.projectFiles(path: projectPath)
            isLoading = false
        }
    }

    private var visibleEntries: [ProjectFileEntry] {
        entries.filter { entry in
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

    private func empty(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.scifiTertiary)
        }
        .foregroundStyle(Color.scifiFg)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scifiGlassPane()
    }
}

/// Real interactive terminal view following DESIGN.md glass pane & typography specifications.
struct SessionTerminalView: View {
    let projectPath: String?
    @StateObject private var terminal = LocalTerminalSession()
    @State private var command = ""
    @FocusState private var commandFocused: Bool

    private var directoryName: String {
        guard let projectPath, !projectPath.isEmpty else { return "TERMINAL" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    private var statusColor: Color {
        switch terminal.state {
        case .running: Color.scifiSuccess
        case .starting: Color.scifiWarning
        case .closed, .idle: Color.scifiMuted
        case .failed: Color.scifiDestructive
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
            // Terminal Header Bar with status indicator and quick actions
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiAccent)

                Text("TERMINAL  ·  \(directoryName.uppercased())")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.75)
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)

                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(statusText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)

                Spacer(minLength: 0)

                // Quick Terminal Action Buttons
                Button("CTRL+C") {
                    terminal.interrupt()
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiWarning)

                Button("CLEAR") {
                    terminal.clear()
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)

                Button("RESTART") {
                    if let projectPath { terminal.start(directory: projectPath) }
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }

            // Scrollable Output Window
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminal.output.isEmpty ? "Terminal session initialized. Ready for commands.\n" : terminal.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(terminal.output.isEmpty ? Color.scifiMuted : Color.scifiFg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("terminal-output")
                }
                .frame(minHeight: 220, maxHeight: .infinity)
                .background(Color.scifiCanvas)
                .onChange(of: terminal.output) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("terminal-output", anchor: .bottom)
                    }
                }
            }

            // Command Prompt Input Bar
            HStack(spacing: 8) {
                Text("❯")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.scifiAccent)

                TextField("Type a shell command (e.g. git status, npm test)...", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiFg)
                    .focused($commandFocused)
                    .onSubmit { submit() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.scifiSurface2)
            .overlay(alignment: .top) { Color.scifiBorderLight.frame(height: 0.5) }
        }
        .scifiGlassPane()
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
}
