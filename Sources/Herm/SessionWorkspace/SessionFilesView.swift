import AppKit
import SwiftUI

/// VS Code-style project explorer: folders-first tree with indent guides, git
/// status decorations, filter, and context actions. Opening a file pushes the
/// code workspace in place, or hands it to `onOpenFile` for a separate pane.
struct SessionFilesView: View {
    let projectPath: String?
    let onRefresh: () async -> Void
    var scope: SessionRepositoryScope? = nil
    var isCompact = false
    var onOpenFile: ((SessionRepositoryScope, RepositoryFileDocument) -> Void)? = nil
    @Environment(\.chatContextRouter) private var contextRouter
    @State private var entries: [ProjectFileEntry] = []
    @State private var gitStatus: [String: RepositoryFileStatus] = [:]
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

    private var presentationIdentity: String {
        (contextRouter?.model.map { WorkspaceIdentity.session($0) } ?? scope?.identity ?? "local") + ":files:"
            + (projectPath ?? "")
    }
    private func savePresentation() {
        WorkspacePresentationStore.shared.saveReferences(
            ExplorerPresentation(
                selected: selectedPath, openFile: document?.path,
                expandedDirectories: Array(expandedDirectories.sorted().prefix(200))), identity: presentationIdentity)
    }
    private static let indentWidth: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document, let projectPath, onOpenFile == nil {
                RepositoryCodeWorkspaceView(
                    repositoryPath: projectPath,
                    document: document,
                    onClose: { self.document = nil },
                    onSave: { draft in
                        guard
                            await RepositoryService.saveDocument(
                                path: projectPath, filePath: document.path, contents: draft)
                        else { return false }
                        await onRefresh()
                        await reloadGitStatus()
                        return true
                    }
                )
                .padding(.vertical, 8)
            } else if projectPath != nil {
                explorer
            } else {
                SessionProjectRequiredState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(presentationIdentity):\(showsGeneratedFiles)") {
            let identity = presentationIdentity
            let saved = WorkspacePresentationStore.shared.loadReferences(ExplorerPresentation.self, identity: identity)
            selectedPath = saved?.selected
            expandedDirectories = Set((saved?.expandedDirectories ?? []).filter(RepositoryService.isSafeRelativePath))
            await reload(resetDisclosure: false)
            guard !Task.isCancelled, presentationIdentity == identity else { return }
            if onOpenFile == nil, document == nil, let file = saved?.openFile, let projectPath,
                RepositoryService.isSafeRelativePath(file)
            {
                let loaded = await RepositoryService.loadDocument(path: projectPath, filePath: file)
                guard !Task.isCancelled, presentationIdentity == identity else { return }
                document = loaded
                if loaded == nil {
                    error = "The previously open file is unavailable. Choose another file or refresh Explorer."
                }
            }
        }
        .onChange(of: selectedPath) { _, _ in savePresentation() }
        .onChange(of: document?.path) { _, _ in savePresentation() }
        .onChange(of: expandedDirectories) { _, _ in savePresentation() }
        .onChange(of: scope?.identity ?? projectPath ?? "") { _, _ in
            openRequestID = UUID()
            isOpeningFile = false
            document = nil
            selectedPath = nil
            error = nil
        }
    }

    // MARK: Tree

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 0) {
            explorerHeader
            filterField
            if let error {
                DockIconLabel(error, icon: .warning)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isLoading, entries.isEmpty {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Loading files…")
                        }
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                        .padding(12)
                    } else if entries.isEmpty {
                        empty(
                            .folder, "No files to show",
                            showsGeneratedFiles
                                ? "The selected project folder has no readable files."
                                : "Generated folders are hidden. Use Explorer options to show them.")
                    } else if visibleEntries.isEmpty {
                        Text("No files match “\(filterText)”")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockMetadataText)
                            .padding(12)
                    } else {
                        ForEach(visibleEntries) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func row(_ entry: ProjectFileEntry) -> some View {
        let isExpanded = !filterQuery.isEmpty || expandedDirectories.contains(entry.path)
        let isSelected = selectedPath == entry.path && !entry.isDirectory
        let status = entry.isDirectory ? folderStatus(entry.path) : gitStatus[entry.path]
        return Button {
            entry.isDirectory ? toggle(entry.path) : open(entry)
        } label: {
            HStack(spacing: 5) {
                Group {
                    if entry.isDirectory {
                        DockIcon(isExpanded ? .caretDown : .caretRight)
                            .dockFont(size: 9, weight: .bold)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .frame(width: 12)
                if entry.isDirectory {
                    DockIcon(isExpanded ? .folderOpen : .folderSimple, weight: .fill)
                        .dockFont(.navigation)
                        .foregroundStyle(Color.dockFolder.opacity(0.85))
                        .frame(width: 16)
                } else {
                    ExplorerFileIcon(path: entry.path, size: 13).frame(width: 16)
                }
                highlightedName(entry)
                    .dockFont(size: 12.5)
                    .foregroundStyle(status.map(Self.color(for:)) ?? Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(status == .deleted)
                Spacer(minLength: 4)
                if isOpeningFile && selectedPath == entry.path {
                    ProgressView().controlSize(.mini)
                } else if let status {
                    if entry.isDirectory {
                        Circle().fill(Self.color(for: status)).frame(width: 5, height: 5).padding(.trailing, 3)
                    } else {
                        Text(Self.letter(for: status))
                            .dockFont(.metadata, weight: .semibold, design: .monospaced)
                            .foregroundStyle(Self.color(for: status))
                    }
                }
            }
            .padding(.leading, CGFloat(entry.depth) * Self.indentWidth + 6)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: ExplorerWorkspaceMetrics.treeRowHeight, alignment: .leading)
            .background(alignment: .leading) { indentGuides(depth: entry.depth) }
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .dockSelectionFill(
                        isSelected,
                        fallback: isSelected
                            ? Color.dockAccent.opacity(0.16)
                            : hoveredPath == entry.path ? Color.dockSurface4.opacity(0.55) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .disabled(isOpeningFile && !entry.isDirectory)
        .onHover { hoveredPath = $0 ? entry.path : (hoveredPath == entry.path ? nil : hoveredPath) }
        .help(entry.path)
        .accessibilityLabel(
            entry.isDirectory ? "\(isExpanded ? "Collapse" : "Expand") \(entry.path)" : "Open \(entry.path)"
        )
        .contextMenu { contextMenu(for: entry) }
    }

    private func indentGuides(depth: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Color.dockBorderLight
                    .frame(width: DockLayout.hairline)
                    .padding(.leading, Self.indentWidth - DockLayout.hairline)
            }
        }
        .padding(.leading, 6)
    }

    private func highlightedName(_ entry: ProjectFileEntry) -> Text {
        let name = entryName(entry)
        guard !filterQuery.isEmpty, let range = name.range(of: filterQuery, options: .caseInsensitive) else {
            return Text(name)
        }
        var attributed = AttributedString(name)
        if let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
        {
            attributed[lower..<upper].foregroundColor = .dockAccent
            attributed[lower..<upper].font = .system(size: 12.5, weight: .bold)
        }
        return Text(attributed)
    }

    @ViewBuilder
    private func contextMenu(for entry: ProjectFileEntry) -> some View {
        if entry.isDirectory {
            Button(expandedDirectories.contains(entry.path) ? "Collapse" : "Expand") { toggle(entry.path) }
        } else {
            Button("Open") { open(entry) }
        }
        Divider()
        Button("Copy Relative Path") { copy(entry.path) }
        Button("Copy Path") { copy(absoluteURL(entry)?.path ?? entry.path) }
        Divider()
        Button("Reveal in Finder") { absoluteURL(entry).map { ExternalOpen.reveal([$0]) } }
        if !entry.isDirectory {
            Button("Open in Default App") { absoluteURL(entry).map(ExternalOpen.open) }
        }
    }

    // MARK: Header

    private var explorerHeader: some View {
        HStack(spacing: 4) {
            Text(projectName.uppercased())
                .dockFont(.metadata, weight: .bold)
                .tracking(0.6)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ExplorerToolbarButton(icon: .arrowsInLineVertical, help: "Collapse all folders") {
                expandedDirectories.removeAll()
            }
            .disabled(expandedDirectories.isEmpty)
            ExplorerToolbarButton(icon: .arrowClockwise, help: "Refresh files and git status", isBusy: isRefreshing) {
                Task { await refresh() }
            }
            .disabled(isRefreshing)
            DockMenu {
                Button {
                    showsGeneratedFiles.toggle()
                } label: {
                    Label("Show generated files", icon: showsGeneratedFiles ? .eye : .eyeSlash)
                }
                Button {
                    projectPath.map { ExternalOpen.reveal([URL(fileURLWithPath: $0)]) }
                } label: {
                    Label("Reveal project in Finder", icon: .folderOpen)
                }
            } label: {
                ExplorerToolbarIcon(icon: .dotsThree)
            }
            // `.borderlessButton` drops custom-shape labels on macOS.
            .buttonStyle(.dockHover)
            .fixedSize()
            .dockHoverTip("Explorer options", edge: .leading)
            .accessibilityLabel("Explorer options")
        }
        .frame(height: ExplorerWorkspaceMetrics.headerHeight)
    }

    private var filterField: some View {
        HStack(spacing: 7) {
            DockIcon(.magnifyingGlass)
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockMetadataText)
            DockTextField("Search files by name", text: $filterText)
                .textFieldStyle(.plain)
                .dockFont(.body)
                .foregroundStyle(Color.dockPrimaryText)
                .onSubmit { if let first = visibleEntries.first(where: { !$0.isDirectory }) { open(first) } }
            if !filterText.isEmpty {
                Text("\(visibleEntries.filter { !$0.isDirectory }.count)")
                    .dockFont(.metadata, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockMetadataText)
                Button {
                    filterText = ""
                } label: {
                    DockIcon(.xCircle, weight: .fill).dockFont(.body)
                }
                .buttonStyle(.dockHover)
                .foregroundStyle(Color.dockMetadataText)
                .accessibilityLabel("Clear file filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).dockSurfaceFill(
                Color.dockSurface2.opacity(0.72))
        )
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .padding(.bottom, 8)
    }

    // MARK: Git status

    private func folderStatus(_ path: String) -> RepositoryFileStatus? {
        let prefix = path + "/"
        let statuses = gitStatus.filter { $0.key.hasPrefix(prefix) }.map(\.value)
        if statuses.contains(.conflicted) { return .conflicted }
        if statuses.contains(.modified) || statuses.contains(.renamed) { return .modified }
        return statuses.first
    }

    static func letter(for status: RepositoryFileStatus) -> String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        case .unknown: "?"
        }
    }

    static func color(for status: RepositoryFileStatus) -> Color {
        switch status {
        case .modified: DockCategoryTone.modified.color
        case .renamed: DockCategoryTone.renamed.color
        case .added, .untracked: .dockSuccess
        case .deleted, .conflicted: .dockDestructive
        case .unknown: .dockSecondaryText
        }
    }

    /// Git reports root-relative paths; the explorer lists project-relative ones.
    static func projectRelativeStatus(_ files: [RepositoryFileChange], projectPrefix: String) -> [String:
        RepositoryFileStatus]
    {
        var result: [String: RepositoryFileStatus] = [:]
        // Worktree status first so it wins over the staged entry for the same path.
        for file in files.sorted(by: { !$0.isStaged && $1.isStaged }) where file.path.hasPrefix(projectPrefix) {
            let path = String(file.path.dropFirst(projectPrefix.count))
            if result[path] == nil { result[path] = file.status }
        }
        return result
    }

    // MARK: Data

    private var projectName: String {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Explorer"
    }

    private var filterQuery: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var visibleEntries: [ProjectFileEntry] {
        if !filterQuery.isEmpty {
            var paths = Set<String>()
            for entry in entries where !entry.isDirectory && entryName(entry).lowercased().contains(filterQuery) {
                paths.insert(entry.path)
                let components = entry.path.split(separator: "/").map(String.init)
                for index in 0..<max(0, components.count - 1) {
                    paths.insert(components[...index].joined(separator: "/"))
                }
            }
            return entries.filter { paths.contains($0.path) }
        }
        return entries.filter { entry in
            let components = entry.path.split(separator: "/").map(String.init)
            for index in 0..<max(0, components.count - 1)
            where !expandedDirectories.contains(components[...index].joined(separator: "/")) {
                return false
            }
            return true
        }
    }

    /// Folders before files at every level, each group in Finder order.
    static func foldersFirst(_ entries: [ProjectFileEntry]) -> [ProjectFileEntry] {
        let parts = entries.map { $0.path.split(separator: "/").map(String.init) }
        let order = entries.indices.sorted { a, b in
            let x = parts[a]
            let y = parts[b]
            for index in 0..<min(x.count, y.count) where x[index] != y[index] {
                let xIsFolder = index < x.count - 1 || entries[a].isDirectory
                let yIsFolder = index < y.count - 1 || entries[b].isDirectory
                if xIsFolder != yIsFolder { return xIsFolder }
                return x[index].localizedStandardCompare(y[index]) == .orderedAscending
            }
            return x.count < y.count
        }
        return order.map { entries[$0] }
    }

    private func entryName(_ entry: ProjectFileEntry) -> String {
        entry.path.split(separator: "/").last.map(String.init) ?? entry.path
    }

    private func absoluteURL(_ entry: ProjectFileEntry) -> URL? {
        projectPath.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.path) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func toggle(_ path: String) {
        if expandedDirectories.contains(path) {
            expandedDirectories.remove(path)
            return
        }
        expandedDirectories.insert(path)
        Task { await loadChildren(of: path) }
    }

    /// The initial scan is budgeted, so a folder may arrive without its
    /// children. Load the folder's own level on expand, like VS Code.
    private func loadChildren(of directory: String) async {
        guard let projectPath else { return }
        let children = await RepositoryService.projectDirectory(
            path: projectPath, directory: directory, includeGenerated: showsGeneratedFiles)
        let known = Set(entries.map(\.id))
        let missing = children.filter { !known.contains($0.id) }
        if !missing.isEmpty { entries = Self.foldersFirst(entries + missing) }
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
                error = "\(entryName(entry)) can't be shown. Only UTF-8 text files up to 256 KB open inline."
                return
            }
            if let onOpenFile, let requestedScope {
                onOpenFile(requestedScope, loaded)
            } else {
                document = loaded
            }
        }
    }

    private func refresh() async {
        guard projectPath != nil else { return }
        isRefreshing = true
        await onRefresh()
        await reload(resetDisclosure: false)
        isRefreshing = false
    }

    private func reload(resetDisclosure: Bool) async {
        guard let projectPath else {
            entries = []
            return
        }
        isLoading = true
        entries = Self.foldersFirst(
            await RepositoryService.projectFiles(path: projectPath, includeGenerated: showsGeneratedFiles))
        if resetDisclosure { expandedDirectories.removeAll() }
        isLoading = false
        for directory in expandedDirectories { await loadChildren(of: directory) }
        await reloadGitStatus()
    }

    private func reloadGitStatus() async {
        guard let projectPath, let root = RepositoryService.repositoryRoot(projectPath) else {
            gitStatus = [:]
            return
        }
        let snapshot = await RepositoryService.changeSnapshot(path: projectPath)
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let prefix = project.hasPrefix(root + "/") ? String(project.dropFirst(root.count + 1)) + "/" : ""
        gitStatus = Self.projectRelativeStatus(snapshot.files, projectPrefix: prefix)
    }

    private func empty(_ icon: Ph, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockIconLabel(title, icon: icon).dockFont(.body, weight: .semibold)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockMetadataText)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
