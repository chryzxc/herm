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

struct SessionTerminalView: View {
    let projectPath: String?
    @StateObject private var terminal = LocalTerminalSession()
    @State private var command = ""
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminal.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiFg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .id("terminal-output")
                }
                .frame(maxHeight: .infinity)
                .background(Color.scifiCanvas)
                .onChange(of: terminal.output) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("terminal-output", anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                Text("❯").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Color.scifiAccent)
                TextField("Type a command", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiFg)
                    .focused($commandFocused)
                    .onSubmit { submit() }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Color.scifiBorderLight.frame(height: 0.5) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct SessionBrowserView: View {
    @ObservedObject var model: DockModel

    var body: some View {
        let events = model.agentActivities.filter { activity in
            let tool = activity.toolName?.lowercased() ?? ""
            return tool.contains("browser") || tool.contains("web") || tool.contains("search")
        }
        VStack(alignment: .leading, spacing: 8) {
            if events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No browser activity", systemImage: "safari") .font(.system(size: 12, weight: .semibold))
                    Text("A live web page will appear here when Hermes exposes a browser-session capability. This Dock currently shows only Hermes-reported browser activity.")
                        .font(.system(size: 12)).foregroundStyle(Color.scifiTertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scifiGlassPane()
            } else {
                Text("HERMES BROWSER ACTIVITY · \(events.count)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Color.scifiMuted)
                ForEach(events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.toolName?.uppercased() ?? "BROWSER").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Color.scifiAccent)
                        Text(event.text).font(.system(size: 12)).foregroundStyle(Color.scifiFg).lineLimit(3)
                    }.padding(.vertical, 5).overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
                }
            }
        }
    }
}
