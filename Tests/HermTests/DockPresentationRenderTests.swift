import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockPresentationRenderTests {
    @Test func renderSurfacesAndNativeForwardPopover() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERM_SURFACE_UI_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = savedAppearance
        }
        let name = "PresentationFixture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent(name), defaults: defaults,
            initialSessionID: "surface-fixture", rpcClient: PresentationFixtureRPC())
        defer { model.shutdown() }
        let botMode = BotModeModel()
        let bot = BotSummary(
            id: "default", name: "Nexus", title: nil, description: nil, model: nil, isActive: true, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: true)
        for (theme, dark) in [(DockThemeID.glass, false), (.glass, true), (.clean, false), (.mono, true)] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let state = PresentationFixtureState()
            let host = NSHostingView(
                rootView: PresentationFixture(state: state, model: model, botMode: botMode, bot: bot)
                    .frame(width: 500).padding(24).dockPresentationSurface()
                    .environment(\.colorScheme, dark ? .dark : .light))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            try capture(host, to: directory.appendingPathComponent("surfaces-\(theme)-\(dark).png"))
            let existing = Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            state.recipient = bot
            var presented: NSWindow?
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                presented = NSApplication.shared.windows.first {
                    $0.isVisible && !existing.contains(ObjectIdentifier($0))
                }
                if presented != nil { break }
            }
            let popover = try #require(presented, "Forward popover did not open")
            let content = try #require(popover.contentView?.superview)
            try await Task.sleep(for: .milliseconds(100))
            try capture(content, to: directory.appendingPathComponent("forward-\(theme)-\(dark).png"))
            state.recipient = nil
            try await Task.sleep(for: .milliseconds(100))
            state.showsSheet = true
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                if window.attachedSheet != nil { break }
            }
            let sheet = try #require(window.attachedSheet, "Fixture sheet did not open")
            let sheetFrame = try #require(sheet.contentView?.superview)
            try await Task.sleep(for: .milliseconds(100))
            try capture(sheetFrame, to: directory.appendingPathComponent("sheet-\(theme)-\(dark).png"))
            state.showsSheet = false
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    }
}

@MainActor
private final class PresentationFixtureState: ObservableObject {
    @Published var recipient: BotSummary?
    @Published var showsSheet = false
}

private struct PresentationFixture: View {
    @ObservedObject var state: PresentationFixtureState
    let model: DockModel
    let botMode: BotModeModel
    let bot: BotSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Shared surfaces").dockFont(.pageTitle)
            VStack(alignment: .leading, spacing: 8) {
                Text("Card container").dockFont(.rowTitle)
                Text("A white surface above the neutral canvas.").dockFont(.body)
                DockTextField("Search", text: .constant("")).textFieldStyle(.dockGlass)
            }.dockCard()
            SettingsSection(title: "Preferences", subtitle: "", tint: .dockAccent) {
                Text("Settings groups use the same card treatment.").dockFont(.body)
            }
            Text("Floating panel").dockFont(.body).padding(16)
                .dockFloatingSurface(DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane))
            Button("Forward to Nexus") { state.recipient = bot }
                .buttonStyle(.dockPrimary)
                .dockPopover(item: $state.recipient, arrowEdge: .bottom) { bot in
                    ForwardToBotPopover(
                        model: model, botMode: botMode, bot: bot,
                        messageText: "I fetched and checked origin/CRX-develop.", dismiss: { state.recipient = nil })
                }
            Button("Open sheet") { state.showsSheet = true }
                .buttonStyle(.dockSecondary)
                .dockSheet(isPresented: $state.showsSheet) {
                    DockModal(title: "Workspace preferences", width: 400) {
                        Text("Sheets share the neutral presentation canvas.").dockFont(.body)
                        DockTextField("Name", text: .constant("")).textFieldStyle(.dockGlass)
                    } footer: {
                        Spacer()
                        Button("Close") { state.showsSheet = false }.buttonStyle(.dockSecondary)
                    }
                }
        }
    }
}

@MainActor
private final class PresentationFixtureRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
