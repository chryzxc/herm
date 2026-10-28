import AppKit
import SwiftUI
import Testing

@testable import Herm

@Suite @MainActor
struct SessionDashboardVisualTests {
    @Test func renderSessionListAcrossThemesAndStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["DASHBOARD_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        _ = DockThemeStore.shared
        let originalTheme = DockThemeRuntime.current
        let originalAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = originalTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = originalAppearance
        }
        let suite = "DashboardVisualTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        let control = ControlCenterModel()
        let profileKey = "hermes.dock.selected-profile.v1"
        let originalProfile = UserDefaults.standard.object(forKey: profileKey)
        defer { UserDefaults.standard.set(originalProfile, forKey: profileKey) }
        let bots = BotModeModel()
        let botClient = DashboardBotVisualRPC()
        bots.bind(to: botClient, capabilityAvailable: true)
        await bots.refreshNow(force: true)
        model.isHermesConnected = true
        model.sessions = [
            session("approval", "Fix calendar layout"),
            session("question", "Update the landing page"),
            session(
                "review", "Investigate scrolling and keep the conversation position stable during refresh", unread: true
            ),
            session("working", "Compare hosting options", working: true),
            session("recent", "Document the release process"),
        ]
        model.sessionProjectionState = .ready(model.sessions)
        control.attention = [
            AttentionItem(
                id: "approval", reference: .init(source: .hermesApproval, sourceID: "approval", sessionID: "approval"),
                kind: .approval, title: "Run build", detail: "Run the project build", createdAt: Date(),
                state: .open, actions: [.approve, .deny]),
            AttentionItem(
                id: "question",
                reference: .init(source: .hermesClarification, sourceID: "question", sessionID: "question"),
                kind: .clarification, title: "Keep pricing?", detail: "Should I keep the pricing section?",
                createdAt: Date(),
                state: .open, actions: [.respond]),
        ]
        let source = SessionNavSidebarModel(
            model: model, control: control,
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/dashboard-\(UUID()).json")))
        for (theme, dark) in [(DockThemeID.clean, false), (.storm, true), (.glass, false), (.mono, true)] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [CGFloat(1180), 380] {
                for current in [true, false] {
                    var selection = SessionDashboardSelection()
                    let request = selection.begin(model.sessions[0])
                    if current { selection.finish(request, loaded: true) }
                    let root = DockExpandedPage(
                        title: "Chats", subtitle: "All projects in the selected bot", showsClose: false, close: {}
                    ) {
                        SessionDashboardToolbar(
                            bots: bots, fallbackName: "Herm", isLoading: !current, isRefreshing: false,
                            onRefresh: {}, onShowList: {}, onNewConversation: {})
                    } content: {
                        SessionDashboardList(
                            sidebar: source, selection: selection, isCurrent: current, onSelect: { _ in })
                    }
                    .frame(width: width, height: 1000).background(DockWindowBackground()).dockThemedRoot()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: root)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.orderFrontRegardless()
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(40))
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "\(theme.rawValue)-\(current)-\(Int(width)).png"))
                    window.orderOut(nil)
                }
            }
        }
    }

    private func session(_ id: String, _ title: String, working: Bool = false, unread: Bool = false) -> HermesSession {
        HermesSession(
            id: id, title: title, preview: "Review the latest work and continue the conversation.", startedAt: nil,
            updatedAt: Date().addingTimeInterval(-120), messageCount: 3, source: "conversation",
            isWorking: working, hasUnreadUpdate: unread)
    }
}

@MainActor
private final class DashboardBotVisualRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "profiles.list" {
            return ["profiles": [["name": "default", "display_name": "Nexus"]]]
        }
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
}
