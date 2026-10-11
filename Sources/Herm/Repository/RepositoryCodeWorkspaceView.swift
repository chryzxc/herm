import AppKit
import SwiftUI

/// Single-file code viewer/editor used by the Explorer and Changes surfaces:
/// breadcrumb header with editor actions, a gutter with line numbers and
/// toggleable git blame, inline blame for the caret line, and a status bar.
struct RepositoryCodeWorkspaceView: View {
    let repositoryPath: String
    let document: RepositoryFileDocument
    let onClose: () -> Void
    let onSave: (String) async -> Bool
    /// Standalone panes fill their container and omit the card chrome and back button.
    var isStandalonePane = false

    @AppStorage("codeWorkspace.showsBlame") private var showsBlame = true
    @AppStorage("codeWorkspace.wrapsLines") private var wrapsLines = false
    @State private var draft: String
    @State private var savedDraft: String
    @State private var blameState: BlameState = .loading
    @State private var hover: CodeEditorBlameHover?
    @State private var cursor = CodeEditorCursor()
    @State private var findRequest = 0
    @State private var githubRemote: GitHubRepositoryReference?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showsDiscardConfirmation = false

    private enum BlameState: Equatable {
        case loading
        case loaded(RepositoryBlameDocument)
        case unavailable(String)
    }

    init(repositoryPath: String, document: RepositoryFileDocument, onClose: @escaping () -> Void, onSave: @escaping (String) async -> Bool, isStandalonePane: Bool = false) {
        self.repositoryPath = repositoryPath
        self.document = document
        self.onClose = onClose
        self.onSave = onSave
        self.isStandalonePane = isStandalonePane
        _draft = State(initialValue: document.contents)
        _savedDraft = State(initialValue: document.contents)
    }

    private var hasUnsavedChanges: Bool { draft != savedDraft }
    private var language: CodeLanguage { CodeLanguage(path: document.path) }

    /// Blame maps saved line numbers, so it pauses while the draft diverges.
    private var activeBlame: RepositoryBlameDocument? {
        guard !hasUnsavedChanges, case .loaded(let blame) = blameState else { return nil }
        return blame
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            editor
            if let saveError {
                DockIconLabel(saveError, icon: .warning)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dockWarning.opacity(0.08))
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            statusBar
        }
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: isStandalonePane ? 0 : DockLayout.paneRadius + 4, style: .continuous))
        .overlay {
            if !isStandalonePane {
                RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous)
                    .stroke(Color.dockBorderStrong, lineWidth: DockLayout.hairline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Discard unsaved changes?", isPresented: $showsDiscardConfirmation) {
            Button("Discard Changes", role: .destructive, action: onClose)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your edits to \(document.path) have not been saved.")
        }
        .task(id: document.id) {
            await loadBlame()
            githubRemote = await RepositoryService.githubRemote(path: repositoryPath)
        }
        .onChange(of: document.contents) { _, contents in
            draft = contents
            savedDraft = contents
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            if !isStandalonePane {
                toolbarButton(.caretLeft, help: "Back to files (Esc)", tipEdge: .trailing, action: requestClose)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ExplorerFileIcon(path: document.path, size: 13)
                .padding(.leading, isStandalonePane ? 6 : 0)
                .padding(.trailing, 6)
            breadcrumbs
            if hasUnsavedChanges {
                Circle()
                    .fill(Color.dockPrimaryText.opacity(0.75))
                    .frame(width: 7, height: 7)
                    .padding(.leading, 6)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer(minLength: 8)
            toolbarButton(.gitCommit, help: showsBlame ? "Hide git blame" : "Show git blame (who last changed each line)", isOn: showsBlame) {
                showsBlame.toggle()
            }
            toolbarButton(.textAlignLeft, help: wrapsLines ? "Turn off word wrap" : "Wrap long lines", isOn: wrapsLines) {
                wrapsLines.toggle()
            }
            toolbarButton(.magnifyingGlass, help: "Find in file (⌘F)") { findRequest += 1 }
            moreMenu
            toolbarButton(isSaving ? .dotsThree : .floppyDisk, help: isSaving ? "Saving…" : "Save (⌘S)", tint: hasUnsavedChanges ? .dockAccent : nil, action: save)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasUnsavedChanges || isSaving)
        }
        .padding(.horizontal, 6)
        .frame(height: ExplorerWorkspaceMetrics.headerHeight)
    }

    private var breadcrumbs: some View {
        let components = document.path.split(separator: "/").map(String.init)
        return HStack(spacing: 3) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    DockIcon(.caretRight)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.dockMetadataText)
                }
                Text(component)
                    .font(.system(size: 12, weight: index == components.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == components.count - 1 ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(index == components.count - 1 ? 1 : 0)
            }
        }
        .help(document.path)
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy Relative Path") { copy(document.path) }
            Button("Copy Path") { copy(absoluteURL?.path ?? document.path) }
            Divider()
            Button("Reveal in Finder") { absoluteURL.map { ExternalOpen.reveal([$0]) } }
            Button("Open in Default App") { absoluteURL.map(ExternalOpen.open) }
            if let githubRemote {
                Button("Open on GitHub") { ExternalOpen.open(githubFileURL(githubRemote)) }
            }
            Divider()
            Button("Reload Blame") { Task { await loadBlame() } }
            if hasUnsavedChanges {
                Button("Revert Unsaved Changes", role: .destructive) { draft = savedDraft }
            }
        } label: {
            ExplorerToolbarIcon(icon: .dotsThree)
        }
        // `.borderlessButton` drops custom-shape labels on macOS.
        .menuStyle(.button)
        .buttonStyle(.dockHover)
        .menuIndicator(.hidden)
        .fixedSize()
        .dockHoverTip("More file actions", edge: .leading)
        .accessibilityLabel("More file actions")
    }

    private func toolbarButton(_ icon: Ph, help: String, isOn: Bool = false, tint: Color? = nil, tipEdge: Edge = .leading, action: @escaping () -> Void) -> some View {
        ExplorerToolbarButton(icon: icon, help: help, isOn: isOn, tint: tint, tipEdge: tipEdge, action: action)
    }

    // MARK: Editor

    private var editor: some View {
        GeometryReader { proxy in
            CodeEditor(
                text: $draft,
                filePath: document.path,
                blame: activeBlame,
                showsBlameGutter: showsBlame,
                wrapsLines: wrapsLines,
                findRequest: findRequest,
                onCursorChange: { cursor = $0 },
                onHoverBlame: { hover = $0 },
                commitURL: { commit in githubRemote.map { $0.webURL.appendingPathComponent("commit/\(commit.hash)") } }
            )
            .overlay(alignment: .topLeading) {
                if let hover {
                    blameCard(hover.line)
                        .offset(
                            x: CodeGutterView.blameWidth + 6,
                            y: hover.y > proxy.size.height - 150 ? max(0, hover.y - 130) : hover.y + 20
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(minHeight: isStandalonePane ? nil : 240)
    }

    private func blameCard(_ line: RepositoryBlameLine) -> some View {
        let commit = line.commit
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(commit.isUncommitted ? "?" : String(commit.author.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.dockOnAccentText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(commit.isUncommitted ? Color.dockWarning : Color.dockAccent))
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.isUncommitted ? "Not committed yet" : commit.author)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    if let date = commit.authoredAt, !commit.isUncommitted {
                        Text("\(HumanDateFormatting.relative(date)) · \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
            }
            if !commit.isUncommitted {
                Text(commit.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    DockIcon(.gitCommit).font(.system(size: 11))
                    Text(commit.shortHash).font(.system(size: 11, design: .monospaced))
                    Spacer(minLength: 0)
                    Text("Right-click for actions").font(.system(size: 10))
                }
                .foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockOpaqueCanvas))
        .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderStrong, lineWidth: DockLayout.hairline))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            blameStatus
            Spacer(minLength: 8)
            Text(cursor.selectedCharacters > 0
                 ? "Ln \(cursor.line), Col \(cursor.column) (\(cursor.selectedCharacters) selected)"
                 : "Ln \(cursor.line), Col \(cursor.column)")
            Text("\(draft.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }) lines")
            Text(ByteCountFormatter.string(fromByteCount: Int64(document.byteCount), countStyle: .file))
            Text("UTF-8")
            Text(language.name)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.dockMetadataText)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.dockSurface2.opacity(0.5))
    }

    @ViewBuilder
    private var blameStatus: some View {
        switch blameState {
        case .loading:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Loading blame…") }
        case .unavailable(let reason):
            DockIconLabel("No blame", icon: .gitCommit).help(reason)
        case .loaded(let blame):
            if hasUnsavedChanges {
                DockIconLabel("Blame paused while editing", icon: .gitCommit)
            } else {
                DockIconLabel("\(Set(blame.lines.map(\.commit.hash)).count) commits", icon: .gitCommit)
                    .help("Hover the blame column for details")
            }
        }
    }

    // MARK: Actions

    private var absoluteURL: URL? {
        RepositoryService.documentURL(repositoryPath: repositoryPath, filePath: document.path)
    }

    private func githubFileURL(_ remote: GitHubRepositoryReference) -> URL {
        remote.webURL.appendingPathComponent("blob/HEAD/\(document.path)")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func loadBlame() async {
        blameState = .loading
        let requested = document.id
        let result = await RepositoryService.blame(path: repositoryPath, filePath: document.path)
        guard requested == document.id else { return }
        switch result {
        case .available(let blame): blameState = .loaded(blame)
        case .unavailable(let reason): blameState = .unavailable(reason)
        }
    }

    private func save() {
        guard hasUnsavedChanges, !isSaving else { return }
        isSaving = true
        saveError = nil
        let snapshot = draft
        Task {
            let succeeded = await onSave(snapshot)
            isSaving = false
            if succeeded {
                savedDraft = snapshot
                await loadBlame()
            } else {
                saveError = "Could not save this file. It may no longer be a regular UTF-8 file."
            }
        }
    }

    private func requestClose() {
        if hasUnsavedChanges { showsDiscardConfirmation = true } else { onClose() }
    }
}

/// File-type glyph with a language tint, shared by the tree and editor header.
struct ExplorerFileIcon: View {
    let path: String
    var size: CGFloat = 13

    var body: some View {
        let (icon, color) = Self.style(for: path)
        DockIcon(icon)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
    }

    static func style(for path: String) -> (Ph, Color) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "swift": return (.fileCode, Color(red: 0.94, green: 0.45, blue: 0.27))
        case "ts", "mts": return (.fileTs, Color(red: 0.19, green: 0.47, blue: 0.78))
        case "tsx": return (.fileTsx, Color(red: 0.19, green: 0.47, blue: 0.78))
        case "js", "mjs", "cjs": return (.fileJs, Color(red: 0.89, green: 0.78, blue: 0.25))
        case "jsx": return (.fileJsx, Color(red: 0.38, green: 0.78, blue: 0.93))
        case "py": return (.filePy, Color(red: 0.25, green: 0.53, blue: 0.80))
        case "rs": return (.fileRs, Color(red: 0.87, green: 0.55, blue: 0.40))
        case "c", "h": return (.fileC, Color(red: 0.36, green: 0.55, blue: 0.80))
        case "cpp", "cc", "hpp": return (.fileCpp, Color(red: 0.36, green: 0.55, blue: 0.80))
        case "css", "scss", "less": return (.fileCss, Color(red: 0.34, green: 0.53, blue: 0.86))
        case "html", "htm": return (.fileHtml, Color(red: 0.89, green: 0.43, blue: 0.27))
        case "md", "markdown", "mdx": return (.fileMd, Color(red: 0.45, green: 0.65, blue: 0.90))
        case "sql": return (.fileSql, Color(red: 0.85, green: 0.65, blue: 0.30))
        case "json", "jsonc": return (.bracketsCurly, Color(red: 0.89, green: 0.78, blue: 0.25))
        case "yml", "yaml", "toml", "ini", "plist", "xcconfig": return (.gear, Color(red: 0.62, green: 0.55, blue: 0.85))
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns", "ico": return (.fileImage, Color(red: 0.65, green: 0.45, blue: 0.85))
        case "lock", "resolved": return (.fileLock, .dockMetadataText)
        case "go", "rb", "java", "kt", "sh", "zsh", "bash", "m", "mm", "dart", "vue": return (.fileCode, .dockSecondaryText)
        default:
            if name.hasPrefix(".env") || name.hasPrefix(".git") { return (.gear, .dockMetadataText) }
            return (.fileText, .dockSecondaryText)
        }
    }
}

/// Icon-only toolbar control for the Explorer and code workspace headers,
/// with hover feedback and a hover tip (`.help` never shows in Herm's panels).
struct ExplorerToolbarButton: View {
    let icon: Ph
    let help: String
    var isOn = false
    var tint: Color? = nil
    var tipEdge: Edge = .leading
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ExplorerToolbarIcon(icon: icon, isOn: isOn, tint: tint, isBusy: isBusy)
        }
        .buttonStyle(.dockHover)
        .dockHoverTip(help, edge: tipEdge)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct ExplorerToolbarIcon: View {
    let icon: Ph
    var isOn = false
    var tint: Color? = nil
    var isBusy = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Group {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                DockIcon(icon, size: 15)
            }
        }
        .foregroundStyle(tint ?? (isOn || isHovered ? Color.dockPrimaryText : Color.dockSecondaryText))
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                .fill(isOn ? Color.dockAccentMuted : isHovered && isEnabled ? Color.dockSurface4.opacity(0.72) : Color.clear)
        )
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
    }
}
