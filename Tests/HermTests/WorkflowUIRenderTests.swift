import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Real native controls, rendered without starting Herm or a Hermes session.
@MainActor
struct WorkflowUIRenderTests {
    @Test func renderWorkflowSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_WORKFLOW_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let savedTheme = DockThemeRuntime.current
        let savedAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = savedAppearance
        }
        let suite = "WorkflowUI.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: defaults, initialSessionID: "ui-fixture", rpcClient: WorkflowUIRPC())
        defer { model.shutdown() }
        let terminalKey = "ui-review-" + UUID().uuidString
        let terminalStore = TerminalWorkspaceStore.shared.workspace(key: terminalKey + ":/tmp")
        for _ in 0..<3 { terminalStore.add(directory: "/tmp") }
        terminalStore.splitIDs = terminalStore.sessions.map(\.id)
        terminalStore.splitAxis = 0
        for (index, session) in terminalStore.sessions.enumerated() {
            session.emulator.view.feed(text: "\r\nFixture shell \(index + 1) · ready for input\r\n")
        }
        defer { TerminalWorkspaceStore.shared.closeWorkspace(key: terminalKey + ":/tmp") }
        for raw in ["island", "clean", "glass", "mono", "eInk", "warmLight"] {
            if let requested = ProcessInfo.processInfo.environment["HERM_WORKFLOW_UI_THEME"], requested != raw {
                continue
            }
            let theme = try #require(DockThemeID(rawValue: raw))
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            let light = ["clean", "warmLight", "eInk"].contains(raw)
            NSApplication.shared.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            for width in [440.0, 1100.0] {
                let settings = VStack(alignment: .leading, spacing: 17) {
                    SettingsSection(title: "Replies", subtitle: "Visual content", tint: .dockAccent) {
                        GenerativeUISettings().padding(.vertical, -8)
                    }
                    SettingsSection(title: "Window capture", subtitle: "", tint: .dockAccent) {
                        DesktopCaptureSettings().padding(.vertical, -8)
                    }
                }.padding(20)
                try await capture(
                    settings, root: root, name: "settings-\(raw)-\(Int(width))", width: width, height: 390)
            }
            try await capture(
                SavedPromptLibrary(model: model), root: root, name: "saved-prompts-\(raw)", width: 560, height: 440)
            try await capture(
                AttachmentPopover(
                    pasteImageAvailable: false, onSelect: { _ in }, onInsertURL: { _ in }, onSelectSnippet: { _ in }),
                root: root, name: "capture-menu-\(raw)", width: 250, height: nil)
            try await capture(
                SettingsSection(title: "Window capture", subtitle: "", tint: .dockAccent) {
                    DesktopCaptureSettings()
                }.padding(DockSpacing.page),
                root: root, name: "capture-settings-\(raw)", width: 540, height: nil)
            try await capture(
                ConversationContextPicker(model: model), root: root, name: "conversation-picker-\(raw)", width: 750,
                height: 520)
            try await capture(
                ComposerContextPreview(
                    context: ChatContext(
                        id: "excerpt", title: "Terminal · Tests · lines 12–18",
                        body:
                            "swift test --filter DiffSearchTests\n✓ Search reveals a matching collapsed file\n✓ Unicode source remains selectable"
                    )), root: root, name: "context-preview-\(raw)", width: 540, height: 420)
            let expanded = ExpandedReviewRouter()
            expanded.availableWidth = 1000
            #expect(
                expanded.present(
                    SharedDiffView(
                        patch: "@@ -1 +1 @@\n-old\n+new", path: "Sources/Example.swift", expandedPresentation: true)))
            try await capture(
                Color.dockCanvas.modifier(
                    ExpandedReviewHost(
                        model: model, router: expanded,
                        titleRow: DockTitleRow(
                            height: DockWindowChrome.titleRowHeight,
                            leadingClearance: DockWindowChrome.fullWidthTrafficLightClearance))),
                root: root, name: "expanded-review-\(raw)", width: 1000, height: 600)
            expanded.closeAll()
            let noteState = DiffReviewState()
            let noteDocument = DiffDocument(
                path: "Sources/Example.swift",
                patch:
                    "@@ -10,3 +10,3 @@\n func displayTitle(_ value: String) -> String {\n-    value\n+    value.isEmpty ? \"Untitled\" : value\n }"
            )
            noteState.beginNote(
                selection: DiffSelection(lines: noteDocument.lines.filter { $0.newLine != nil }),
                documentID: "captured-revision", path: noteDocument.path, comparison: nil)
            noteState.revisionNotes.register(path: noteDocument.path, identity: "refreshed-revision")
            noteState.note = "Trim whitespace before checking for an empty title."
            try await capture(
                RevisionNoteEditor(state: noteState), root: root, name: "revision-note-\(raw)", width: 460, height: nil)
            try await capture(
                ReviewGuideView(
                    coordinator: ReviewGuideCoordinator(), model: model,
                    currentIdentity: "fixture", directory: nil), root: root, name: "review-guide-\(raw)", width: 900,
                height: 560)
            for width in [352.0, 1200.0] {
                try await capture(
                    SessionTerminalView(
                        projectPath: "/tmp", recipes: [], repositoryID: nil,
                        repositoryFingerprint: nil, workspaceKey: terminalKey, discoveryActive: false), root: root,
                    name: "terminal-splits-\(raw)-\(Int(width))", width: width, height: 640)
                #expect(terminalStore.splitAxis == 0)
            }
        }
    }

    private func capture<V: View>(_ view: V, root: URL, name: String, width: CGFloat, height: CGFloat?) async throws {
        let host = NSHostingView(
            rootView: view.frame(width: width, height: height, alignment: .topLeading)
                .background(Color.dockCanvas).dockThemedRoot()
                .fixedSize(horizontal: false, vertical: height == nil))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? host.fittingSize.height)
        if name.hasPrefix("revision-note-") {
            #expect(host.frame.height > 260)
            #expect(host.frame.height < 460)
        }
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        func terminals(_ view: NSView) -> [ContextTerminalView] {
            (view as? ContextTerminalView).map { [$0] } ?? view.subviews.flatMap(terminals)
        }
        let panes = terminals(host)
        if name.hasPrefix("terminal-splits") {
            #expect(panes.count == 4)
            for pane in panes {
                #expect(pane.bounds.width >= 150)
                #expect(pane.bounds.height >= 90)
                pane.feed(text: "\r\nFixture terminal · selectable output\r\n")
            }
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Hosting-view snapshots omit the embedded terminal's backing layer. Paint its native contents at its actual frame.
        let screenshot = NSImage(size: host.bounds.size)
        screenshot.lockFocus()
        rep.draw(in: host.bounds)
        for pane in panes {
            var frame = pane.convert(pane.bounds, to: host)
            if host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
            let contents = NSImage(size: pane.bounds.size)
            contents.lockFocus()
            pane.effectiveAppearance.performAsCurrentDrawingAppearance {
                pane.draw(pane.bounds)
                // Default cells clear their backing. Metal's layer is transparent, so resolve
                // the terminal's actual background into this isolated image before compositing.
                if let graphics = NSGraphicsContext.current?.cgContext {
                    graphics.setBlendMode(.destinationOver)
                    graphics.setFillColor(pane.nativeBackgroundColor.cgColor)
                    graphics.fill(pane.bounds)
                }
            }
            contents.unlockFocus()
            contents.draw(in: frame)
        }
        screenshot.unlockFocus()
        let bitmap = try #require(NSBitmapImageRep(data: screenshot.tiffRepresentation!))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent(name + ".png"))
    }
}

@MainActor
private final class WorkflowUIRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
