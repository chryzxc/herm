import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct WorkspaceFoundationRenderTests {
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
                    TextSizeSettings()
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
                    IntegrationCard(
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
