import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
@Suite(.serialized)
struct WorkspaceFoundationRenderTests {
    @Test func shortDraftDoesNotExpandComposer() async throws {
        _ = NSApplication.shared
        let name = "ComposerSizing.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            defaults: defaults, initialSessionID: "sizing-fixture", rpcClient: FoundationFixtureRPC())
        defer { model.shutdown() }
        let composer = ChatComposerView(
            model: model, composer: model.composer, speechInput: SpeechInput(), botMode: BotModeModel(), onStop: {})
        let host = NSHostingView(
            rootView: VStack {
                Spacer()
                composer
            }.frame(width: 600, height: 500).dockThemedRoot())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func find(_ view: NSView) -> ComposerInputTextView? {
            if let text = view as? ComposerInputTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        let scroll = try #require(text.enclosingScrollView)
        let initialHeight = scroll.frame.height
        window.makeFirstResponder(text)
        for character in "This" {
            text.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        #expect(abs(scroll.frame.height - initialHeight) < 1)
    }
    @Test func multilineComposerKeepsLastLineVisible() async throws {
        _ = NSApplication.shared
        let oldTheme = DockThemeRuntime.current
        DockThemeRuntime.current = .notebook
        DockThemeRuntime.revision &+= 1
        defer {
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        let name = "ComposerMultiline.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            defaults: defaults, initialSessionID: "sizing-fixture", rpcClient: FoundationFixtureRPC())
        defer { model.shutdown() }
        let widths: [CGFloat] = [420, 790]
        let variants = widths.flatMap { width in
            [DockWorkspaceScale.defaultTextSize, DockWorkspaceScale.compactTextSize].map { (width, $0) }
        }
        for (width, scale) in variants {
            model.draft = ""
            let composer = ChatComposerView(
                model: model, composer: model.composer, speechInput: SpeechInput(), botMode: BotModeModel(), onStop: {})
            let host = NSHostingView(
                rootView: VStack {
                    Spacer()
                    composer
                }
                .frame(width: width, height: 500)
                .environment(\.dockWorkspaceScale, CGFloat(scale))
                .background(Color.dockOpaqueCanvas).dockThemedRoot())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            func find(_ view: NSView) -> ComposerInputTextView? {
                if let text = view as? ComposerInputTextView { return text }
                return view.subviews.lazy.compactMap(find).first
            }
            let text = try #require(find(host))
            let scroll = try #require(text.enclosingScrollView)
            window.makeFirstResponder(text)
            text.insertText(
                "/cpipe safely port the changes here of this PR to IC. This is a PR from CRX: climate/feat/ "
                    + "program-receipt-ai. Branch out from origin IC-develop and",
                replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            expectRectangularEditorAncestors(text, host: host)
            let layout = try #require(text.layoutManager)
            let container = try #require(text.textContainer)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(
                forCharacterRange: NSRange(location: text.string.utf16.count - 1, length: 1),
                actualCharacterRange: nil)
            var lineRange = NSRange()
            _ = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: &lineRange)
            let last = layout.boundingRect(forGlyphRange: lineRange, in: container)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            #expect(
                scroll.documentVisibleRect.contains(last),
                "Last line is clipped at width \(width), scale \(scale)")
            #expect(
                scroll.documentVisibleRect.maxY >= layout.usedRect(for: container).maxY + 2,
                "Last line needs room for descenders")
            if let directory = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(
                    to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("composer-\(Int(width))-\(scale).png"))
            }
        }
    }

    @Test func groupComposerShowsWholeLastLine() async throws {
        _ = NSApplication.shared
        let oldTheme = DockThemeRuntime.current
        DockThemeRuntime.current = .notebook
        DockThemeRuntime.revision &+= 1
        defer {
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        let name = "GroupComposerClipping.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = GroupChatStore(defaults: defaults)
        let view = GroupChatView(
            store: store, botMode: BotModeModel(), roomID: "composer-clipping-fixture",
            toolbar: { title, _ in title }, onDisbanded: {}
        )
        .environment(\.dockHostVisible, false)
        .environment(\.dockWorkspaceScale, CGFloat(DockWorkspaceScale.compactTextSize))
        .frame(width: 420, height: 500)
        .dockThemedRoot()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func find(_ view: NSView) -> ComposerInputTextView? {
            if let text = view as? ComposerInputTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        let scroll = try #require(text.enclosingScrollView)
        window.makeFirstResponder(text)
        text.insertText(
            "/cpipe safely port the changes here of this PR to IC. This is a PR from CRX: climate/feat/ "
                + "program-receipt-ai. Branch out from origin IC-develop and",
            replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        expectRectangularEditorAncestors(text, host: host)
        let layout = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(
            forCharacterRange: NSRange(location: text.string.utf16.count - 1, length: 1),
            actualCharacterRange: nil)
        var lineRange = NSRange()
        _ = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: &lineRange)
        let line = layout.boundingRect(forGlyphRange: lineRange, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        #expect(scroll.documentVisibleRect.contains(line))
        text.insertText(
            String(repeating: "\nLong line with gypqj descenders", count: 16) + "\n",
            replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0))
        layout.ensureLayout(for: container)
        let caretLine = layout.extraLineFragmentUsedRect.offsetBy(
            dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        #expect(scroll.contentView.bounds.height >= ComposerLayout.maxHeight - 1)
        #expect(scroll.contentView.bounds.height <= ComposerLayout.maxHeight)
        #expect(caretLine.height > 0)
        #expect(caretLine.minY >= scroll.documentVisibleRect.minY)
        #expect(caretLine.maxY <= scroll.documentVisibleRect.maxY)
        if let directory = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("group-notebook-420-compact.png"))
        }
    }

    private func expectRectangularEditorAncestors(_ text: NSTextView, host: NSView) {
        var view: NSView? = text
        while let current = view, current !== host {
            #expect(current.layer?.mask == nil, "Editor ancestor has a nonrectangular layer mask")
            view = current.superview
        }
    }

    @Test func preferenceRowsSupportEmptyConditionalAndMultipleControls() {
        for width: CGFloat in [300, 700] {
            for visible in [false, true] {
                let host = NSHostingView(
                    rootView: VStack {
                        SettingsPreferenceRow(title: "Status display", detail: "Choose a display below.") {
                            EmptyView()
                        }
                        SettingsPreferenceRow(title: "Conditional", detail: "Optional controls") {
                            if visible { Text("Available") }
                        }
                        SettingsPreferenceRow(title: "Multiple", detail: "Keep both controls visible") {
                            Text("First")
                            Text("Second")
                        }
                    }.frame(width: width))
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height.isFinite)
                #expect(host.fittingSize.height >= 156)
            }
        }
    }

    @Test func appearancePreferenceContentLaysOut() {
        for width: CGFloat in [360, 700] {
            let host = NSHostingView(
                rootView: VStack {
                    DensitySettings()
                    NotchDisplaySettings()
                }.frame(width: width))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height.isFinite)
            #expect(host.fittingSize.height > 0)
        }
    }

    @Test func preferenceControlsStackOnlyWhenTheyNeedSpace() {
        for (width, controlWidth, stacked) in [(300.0, 52.0, false), (300, 220, true), (600, 220, false)] {
            let probe = FoundationControlView()
            let host = NSHostingView(
                rootView: SettingsPreferenceRow(title: "Default view", detail: "Choose the starting workspace.") {
                    FoundationControlProbe(view: probe).frame(width: controlWidth, height: 28)
                }.frame(width: width))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let control = probe.convert(probe.bounds, to: host)
            #expect(abs(control.width - controlWidth) < 1)
            #expect(host.bounds.contains(control))
            if stacked {
                #expect(abs(control.midY - host.bounds.midY) > 8)
            } else {
                #expect(abs(control.midY - host.bounds.midY) < 1)
            }
        }
    }

    @Test func renderSharedGroupsAndBoundBusyComposer() async throws {
        let savedTheme = DockThemeRuntime.current
        let savedAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = savedAppearance
        }
        let directory = ProcessInfo.processInfo.environment["HERM_FOUNDATION_UI_DIR"].map {
            URL(fileURLWithPath: $0)
        }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let name = "FoundationFixture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            defaults: defaults, initialSessionID: "foundation-fixture", rpcClient: FoundationFixtureRPC())
        defer { model.shutdown() }
        let bots = BotModeModel()
        let speech = SpeechInput()
        for (theme, dark) in [
            (DockThemeID.glass, false), (.glass, true), (.clean, false), (.mono, true),
            (.swiss, false), (.eInk, false), (.origami, false),
        ] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [360, 900] {
                let groups = VStack(alignment: .leading, spacing: DockSpacing.section) {
                    SettingsSection(title: "Replies", subtitle: "Conversation preferences", tint: .dockAccent) {
                        SettingsPreferenceRow(
                            title: "Generative UI",
                            detail: "Show interactive content and structured answers in this conversation."
                        ) { Toggle("Generative UI", isOn: .constant(true)).labelsHidden().toggleStyle(.switch) }
                    }
                    SettingsSection(title: "Workspace", subtitle: "", tint: .dockAccent) {
                        SettingsPreferenceRow(
                            title: "Default view", detail: "Choose how the workspace opens."
                        ) {
                            Picker("Default view", selection: .constant(0)) {
                                Text("Conversation").tag(0)
                                Text("Overview").tag(1)
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                        }
                    }
                    IntegrationInventoryRow(
                        title: "Project tools", detail: "Tools available for the selected workspace.",
                        selected: false, action: {}
                    ) { IntegrationCardIcon(symbol: .folder) }
                    SessionInspectorTabStrip(
                        tabs: ["Explorer", "Terminal", "Browser", "Artifacts"].enumerated().map { index, title in
                            SessionInspectorTabItem(
                                id: title, title: title, icon: .folder, isSelected: index == 0,
                                select: {}, close: {})
                        }, workspace: "fixture", reorder: { _, _ in false })
                }
                if let directory {
                    try await capture(
                        groups, width: width,
                        url: directory.appendingPathComponent("groups-\(theme)-\(dark)-\(Int(width)).png"))
                }
                var heights: [CGFloat] = []
                for count in [1, 12] {
                    model.queuedPrompts = []
                    model.status = .working
                    model.isSending = true
                    for index in 1...count {
                        model.draft = "Queued task \(index): review the workspace changes and report the result."
                        model.queueDraft()
                    }
                    model.draft = "Please keep the current changes focused."
                    let composer = ChatComposerView(
                        model: model, composer: model.composer, speechInput: speech, botMode: bots, onStop: {})
                    let size = try await capture(
                        composer, width: width,
                        url: directory?.appendingPathComponent("composer-\(theme)-\(dark)-\(Int(width))-\(count).png"))
                    heights.append(size.height)
                    #expect(model.currentSessionQueuedPrompts.count == count)
                }
                #expect(heights[1] <= heights[0] + 144, "A long queue must remain bounded above the input")
            }
        }
    }

    @discardableResult
    private func capture<V: View>(_ view: V, width: CGFloat, url: URL?) async throws -> CGSize {
        let host = NSHostingView(
            rootView: view.padding(16).frame(width: width).background(Color.dockOpaqueCanvas).dockThemedRoot())
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        if let url {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        return size
    }
}

@MainActor
private final class FoundationFixtureRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}

private final class FoundationControlView: NSView {}

private struct FoundationControlProbe: NSViewRepresentable {
    let view: FoundationControlView
    func makeNSView(context: Context) -> FoundationControlView { view }
    func updateNSView(_ nsView: FoundationControlView, context: Context) {}
}
