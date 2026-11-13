import AppKit
import SwiftUI
import Testing

@testable import Herm

@Suite(.serialized) @MainActor
struct SessionSidebarStickyHeaderTests {
    @Test func headersStayAtTheScrollViewportAcrossThemesAndWidths() async throws {
        let app = NSApplication.shared
        let oldAccessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        let oldTheme = DockThemeRuntime.current
        let oldAppearance = app.appearance
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer {
            app.appearance = oldAppearance
            app.setValue(oldAccessibility, forKey: "accessibilityEnhancedUserInterface")
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        let suite = "StickySidebar.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = StickySidebarRPC()
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer { model.shutdown() }
        model.sessions = (0..<36).map { index in
            HermesSession(
                id: "session-\(index)", title: "Conversation \(index)", preview: "Saved conversation preview",
                startedAt: nil, messageCount: 2, source: "cli")
        }
        model.sessionProjectionState = .ready(model.sessions)
        model.pinnedSessions = Array(model.sessions.prefix(12))
        let control = ControlCenterModel()
        control.projects = (0..<18).map { index in
            ProjectSummary(
                id: "project-\(index)", name: "Project \(index)", repoCount: 0, sessionCount: 0,
                sessionIDs: [], preview: nil, isActive: false)
        }
        let navigation = SessionNavigationState()
        navigation.hasRequestedSessionIndex = true
        navigation.showsAllConversations = true
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = WorkspaceStore(fileURL: storeURL)
        let bots = BotModeModel()
        let updates = HermesUpdateService()
        let themes: [(DockThemeID, NSAppearance.Name)] = [
            (.clean, .aqua), (.storm, .darkAqua), (.glass, .aqua), (.glass, .darkAqua), (.mono, .darkAqua),
        ]
        for (theme, appearance) in themes {
            app.appearance = NSAppearance(named: appearance)
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            let themeStore = DockThemeStore(defaults: defaults)
            themeStore.selectedThemeID = theme
            for width: CGFloat in [300, 420] {
                let root = SessionNavQueue(
                    model: model, botMode: bots, workspaceStore: store, controlCenter: control,
                    agentUpdateService: updates, navigationState: navigation, dockThemeStore: themeStore,
                    sessionPendingDeletion: .constant(nil), activeSessionID: nil, activeGlobalTab: nil,
                    isArtifactsActive: false, isBotsActive: false, isPullRequestsActive: false, isIssuesActive: false,
                    onNewConversation: {}, onSelectSession: { _ in }, onSelectTask: { _ in }, onOpenGlobal: { _ in },
                    onOpenArtifacts: {}, onOpenBots: {}, onOpenBotChat: { _, _ in },
                    onOpenPullRequests: {}, onOpenIssues: {}, showsFullscreenToggle: false, isFullscreen: false,
                    onFullscreenToggle: {}, onSelectProfile: { _ in }
                )
                .frame(width: width, height: 480)
                .environment(\.dockHostVisible, false)
                .background(Color.dockOpaqueCanvas)
                .dockThemedRoot()
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let scroll = try #require(scrollView(in: host))
                let clip = scroll.contentView
                let document = try #require(scroll.documentView)
                let viewportTop = window.convertToScreen(clip.convert(clip.bounds, to: nil)).maxY
                var previousY: [String: CGFloat] = [:]
                var pinned = Set<String>()
                let labels = ["Collapse Pinned", "Collapse Recents", "Collapse Projects"]
                var offset: CGFloat = 0
                while offset <= document.bounds.height - clip.bounds.height, offset < 10_000 {
                    defer { offset += 100 }
                    clip.scroll(to: NSPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(clip)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                    for label in labels where !pinned.contains(label) {
                        guard let element = elements(host).first(where: { $0.accessibilityLabel?() == label }),
                            let frame = element.accessibilityFrame?(), frame.height > 0,
                            abs(viewportTop - frame.maxY) < 40
                        else { continue }
                        if let previous = previousY[label], abs(previous - frame.maxY) < 1 {
                            pinned.insert(label)
                            if let directory = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"] {
                                try FileManager.default.createDirectory(
                                    atPath: directory, withIntermediateDirectories: true)
                                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                                host.cacheDisplay(in: host.bounds, to: bitmap)
                                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                                try data.write(
                                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                                        "\(theme.rawValue)-\(Int(width))-\(label.replacingOccurrences(of: " ", with: "-")).png"
                                    ))
                            }
                        }
                        previousY[label] = frame.maxY
                    }
                    if pinned.count == labels.count { break }
                }
                #expect(pinned == Set(labels), "Sticky headers at \(theme.rawValue), width \(width): \(pinned)")
            }
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func elements(_ element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
    }
}

@MainActor
private final class StickySidebarRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
}
