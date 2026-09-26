import AppKit
import Combine
import SwiftUI

struct SessionFilesView: View {
    let projectPath: String?
    let onRefresh: () async -> Void
    var scope: SessionRepositoryScope? = nil
    var isCompact = false
    var onOpenFile: ((SessionRepositoryScope, RepositoryFileDocument) -> Void)? = nil
    @State private var entries: [ProjectFileEntry] = []
    @State private var expandedDirectories = Set<String>()
    @State private var document: RepositoryFileDocument?
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var isOpeningFile = false
    @State private var error: String?
    @State private var filterText = ""
    @State private var selectedPath: String?
    @State private var hoveredPath: String?
    @State private var showsGeneratedFiles = false
    @State private var openRequestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document, let projectPath, onOpenFile == nil {
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
                SessionProjectRequiredState()
            }
        }
        .task(id: "\(projectPath ?? ""):\(showsGeneratedFiles)") {
            await reload(resetDisclosure: true)
        }
        .onChange(of: scope?.identity ?? projectPath ?? "") { _, _ in
            openRequestID = UUID()
            isOpeningFile = false
            document = nil
            selectedPath = nil
            error = nil
        }
        // Keep the files surface anchored to the inspector's top edge. Without
        // an explicit alignment, the empty state is centered inside the
        // full-height session inspector.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 0) {
            explorerHeader
            filterField
            statusSlot

            if !isLoading, entries.isEmpty {
                empty(.folder, "No files to show", showsGeneratedFiles ? "The selected project folder has no readable files." : "Generated folders are hidden. Use Explorer options to show them.")
            } else {
                ForEach(visibleEntries) { entry in
                    if entry.isDirectory {
                        Button { toggle(entry.path) } label: {
                            explorerRow(
                                icon: expandedDirectories.contains(entry.path) ? .folder : .folder,
                                title: entryName(entry),
                                path: entry.path,
                                depth: entry.depth,
                                isDirectory: true,
                                isExpanded: expandedDirectories.contains(entry.path),
                                color: Color.dockSecondaryText
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { open(entry) } label: {
                            explorerRow(
                                icon: fileIcon(for: entry),
                                title: entryName(entry),
                                path: entry.path,
                                depth: entry.depth,
                                isDirectory: false,
                                isExpanded: false,
                                color: selectedPath == entry.path ? Color.dockAccent : Color.dockSecondaryText
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpeningFile)
                        .help(entry.path)
                        .accessibilityLabel("Open \(entry.path)")
                    }
                }

                if !isLoading, visibleEntries.isEmpty {
                    Text("No matching files")
                        .font(.system(size: 12))
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

    private func explorerRow(icon: Ph, title: String, path: String?, depth: Int, isDirectory: Bool, isExpanded: Bool, color: Color) -> some View {
        HStack(spacing: 7) {
            if isDirectory {
                DockIcon(isExpanded ? .caretDown : .caretRight)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }

            DockIcon(icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isOpeningFile && selectedPath == path { ProgressView().controlSize(.mini) }
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: ExplorerWorkspaceMetrics.treeRowHeight, maxHeight: ExplorerWorkspaceMetrics.treeRowHeight, alignment: .leading)
        .background {
            if selectedPath == path, !isDirectory {
                Color.dockAccent.opacity(0.14)
            } else if hoveredPath == path {
                Color.dockSurface4.opacity(0.55)
            } else {
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .onHover { hoveredPath = $0 ? path : nil }
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
        let requestID = UUID()
        openRequestID = requestID
        let requestedScope = scope
        Task {
            isOpeningFile = true
            selectedPath = entry.path
            error = nil
            let loaded = await RepositoryService.loadDocument(path: projectPath, filePath: entry.path)
            guard openRequestID == requestID else { return }
            isOpeningFile = false
            guard let loaded else {
                error = "This file cannot be opened inline. Only regular UTF-8 files up to 256 KB are supported."
                return
            }
            if let onOpenFile, let requestedScope {
                onOpenFile(requestedScope, loaded)
            } else {
                document = loaded
            }
        }
    }

    private func fileIcon(for entry: ProjectFileEntry) -> Ph {
        switch entry.path.split(separator: ".").last.map(String.init)?.lowercased() {
        case "ts", "tsx", "js", "jsx", "swift", "py", "go", "rs": .bracketsCurly
        case "json", "yaml", "yml", "toml": .fileText
        case "md", "txt": .fileText
        default: .file
        }
    }

    private var explorerHeader: some View {
        HStack(spacing: 8) {
            DockIcon(.folder)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
            Text(projectName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(entries.filter { !$0.isDirectory }.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            Spacer(minLength: 4)
            Button { Task { await refresh() } } label: {
                Group {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { DockIcon(.arrowClockwise).font(.system(size: 14, weight: .medium)) }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockSecondaryText)
            .disabled(isRefreshing)
            .help("Refresh project files")
            .accessibilityLabel("Refresh project files")
            Menu {
                Button("Collapse all folders") { collapseAll() }
                Toggle("Show generated files", isOn: $showsGeneratedFiles)
            } label: {
                DockIcon(.dotsThree)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(Color.dockSecondaryText)
            .help("Explorer options")
            .accessibilityLabel("Explorer options")
        }
        .frame(height: ExplorerWorkspaceMetrics.headerHeight)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var filterField: some View {
        HStack(spacing: 7) {
            DockIcon(.magnifyingGlass)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
            TextField("Filter files…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockPrimaryText)
            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    DockIcon(.xCircle, weight: .fill)
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockMetadataText)
                .accessibilityLabel("Clear file filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(Color.dockSurface2.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.vertical, 8)
    }

    private var statusSlot: some View {
        HStack(spacing: 7) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Loading files…")
            } else if let error {
                DockIcon(.warning)
                Text(error)
            } else {
                Color.clear.frame(width: 1, height: 1)
                Text(" ")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(error == nil ? Color.dockMetadataText : Color.dockWarning)
        .lineLimit(1)
        .frame(height: 22, alignment: .leading)
    }

    private func collapseAll() { expandedDirectories.removeAll() }

    private func refresh() async {
        guard projectPath != nil else { return }
        isRefreshing = true
        await onRefresh()
        await reload(resetDisclosure: false)
        isRefreshing = false
    }

    private func reload(resetDisclosure: Bool) async {
        guard let projectPath else { entries = []; return }
        isLoading = true
        selectedPath = nil
        let loadedEntries = await RepositoryService.projectFiles(path: projectPath, includeGenerated: showsGeneratedFiles)
        entries = loadedEntries
        if resetDisclosure { expandedDirectories.removeAll() }
        isLoading = false
    }

    private func empty(_ icon: Ph, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockIconLabel(title, icon: icon).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
    }

}

/// Real interactive terminal view following DESIGN.md glass pane & typography specifications.
@MainActor
private final class TerminalTabStore: ObservableObject {
    @Published private(set) var sessions: [LocalTerminalSession]
    @Published var selectedID: LocalTerminalSession.ID
    private var subscriptions: [AnyCancellable] = []

    init() {
        let session = LocalTerminalSession()
        sessions = [session]
        selectedID = session.id
        observe(session)
    }

    var selected: LocalTerminalSession {
        sessions.first(where: { $0.id == selectedID }) ?? sessions[0]
    }

    func add(directory: String) {
        let session = LocalTerminalSession()
        sessions.append(session)
        observe(session)
        selectedID = session.id
        session.start(directory: directory)
    }

    func closeSelected() {
        guard sessions.count > 1 else {
            selected.close()
            return
        }
        let index = sessions.firstIndex(where: { $0.id == selectedID }) ?? 0
        sessions[index].close()
        sessions.remove(at: index)
        subscriptions.removeAll()
        sessions.forEach(observe)
        selectedID = sessions[min(index, sessions.count - 1)].id
    }

    func closeAll() {
        sessions.forEach { $0.close() }
    }

    private func observe(_ session: LocalTerminalSession) {
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}

struct SessionTerminalView: View {
    let projectPath: String?
    let recipes: [VerificationRecipe]
    let repositoryID: String?
    let repositoryFingerprint: String?
    @StateObject private var terminalTabs = TerminalTabStore()

    private var directory: String { projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path }

    private var terminal: LocalTerminalSession { terminalTabs.selected }

    private var canInterrupt: Bool {
        if case .running = terminal.state { return true }
        if case .interrupting = terminal.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            terminalTabBar
            terminalControls
            if let run = terminal.lastVerificationRun {
                verificationRunBanner(run)
            }

            SessionTerminalCanvas(session: terminal)
                .id(terminal.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 8)

        }
        .background(Color.dockCanvas)
        .task(id: projectPath) {
            terminal.start(directory: directory)
        }
        .onDisappear { terminalTabs.closeAll() }
    }

    private var terminalTabBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(terminalTabs.sessions) { session in
                        terminalTab(session)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                terminalTabs.add(directory: directory)
            } label: {
                DockIcon(.plus)
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .help("New terminal session")
        }
        .padding(.horizontal, 0)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func terminalTab(_ session: LocalTerminalSession) -> some View {
        HStack(spacing: 7) {
            DockIcon(.terminal)
                .font(.system(size: 10, weight: .semibold))
            Text("Shell \((terminalTabs.sessions.firstIndex(where: { $0.id == session.id }) ?? 0) + 1)")
                .font(.system(size: 12))
                .lineLimit(1)
            Button {
                terminalTabs.selectedID = session.id
                terminalTabs.closeSelected()
            } label: {
                DockIcon(.x)
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close terminal")
        }
        .foregroundStyle(terminalTabs.selectedID == session.id ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(terminalTabs.selectedID == session.id ? Color.dockSurface6 : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { terminalTabs.selectedID = session.id }
    }

    private var terminalControls: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(URL(fileURLWithPath: directory).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .help(directory)
            if case .failed(let error) = terminal.state {
                Text(error).font(.system(size: 12)).foregroundStyle(Color.dockWarning)
                Button("Retry") { terminal.start(directory: directory) }.buttonStyle(.borderless)
            }
            if terminal.state == .closed || terminal.state == .exited {
                Button("Restart") { terminal.start(directory: directory) }
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: 8)

            if !recipes.isEmpty {
                Menu {
                    ForEach(recipes) { recipe in
                        Button(recipe.title) {
                            guard let repositoryID, let repositoryFingerprint else { return }
                            terminal.runVerification(recipe, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint)
                        }
                        Button("Copy \(recipe.title.lowercased()) command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recipe.command, forType: .string)
                        }
                    }
                } label: {
                    Label("Run check", icon: .sealCheck)
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(Color.dockAccent)
                .help("Run verified repository check")
                .accessibilityLabel("Run verified repository check")
                .accessibilityIdentifier(WorkflowAccessibilityIdentifier.terminalRunVerification)
                .disabled(terminal.state != .ready)
            }

            Menu {
                Button("Clear output") { terminal.clear() }
                Button("Interrupt", action: terminal.interrupt)
                    .disabled(!canInterrupt)
                Button("Restart shell") { terminal.start(directory: directory) }
            } label: {
                DockIcon(.dotsThree).frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Terminal options")

        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func verificationRunBanner(_ run: VerificationRun) -> some View {
        HStack(spacing: 8) {
            Text(run.isComplete ? "\(run.command) · EXIT \(run.exitCode ?? -1)\(run.durationLabel.map { " · \($0)" } ?? "")" : "Running \(run.command)…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(run.isComplete && run.exitCode == 0 ? Color.dockSuccess : Color.dockWarning)
                .lineLimit(1)
            if let recipe = recipes.first(where: { $0.id == run.recipeID }), run.isComplete {
                Button("Rerun") {
                    guard let repositoryID, let repositoryFingerprint else { return }
                    terminal.runVerification(recipe, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .accessibilityLabel("Rerun \(recipe.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .accessibilityLabel(run.isComplete ? "Verification completed with exit code \(run.exitCode ?? -1)" : "Verification running")
    }
}
