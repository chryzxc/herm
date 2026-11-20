import CoreGraphics
import Foundation

/// A detached conversation's window, as the registry sees it. AppKit stays in the
/// controller so the registry's rules can be tested without opening windows.
@MainActor
protocol ConversationWindowHandle: AnyObject {
    func focus()
    func close()
    func retitle(_ title: String)
}

/// What opening a conversation in its own window does, given where it is shown now.
enum ConversationWindowResolution: Equatable {
    case focusWindow
    case openWindow(leaveMain: Bool, removeFromColumn: Bool)
}

/// Conversations detached into their own floating windows, like tabs torn out of a
/// browser. A conversation lives in one place: while it is detached, the main
/// window and split columns focus its window instead of loading it again.
/// Hermes owns the history; windows are views and are not persisted.
@MainActor
final class ConversationWindowStore: ObservableObject {
    static let shared = ConversationWindowStore()
    nonisolated static let cascadeStep: CGFloat = 24

    @Published private(set) var detachedSessionIDs: Set<String> = []
    var makeWindow: (QuickDestination) -> ConversationWindowHandle
    /// The conversation the main window shows now; bound by the app delegate.
    var mainSessionID: () -> String? = { nil }
    /// Sessions shown in split columns; bound by the app delegate.
    var columnSessionIDs: () -> Set<String> = { [] }
    var removeFromColumn: (String) -> Void = { _ in }
    private var windows: [String: ConversationWindowHandle] = [:]
    /// Every mounted workspace (floating panel and full window) leaves the main chat its own way.
    private var leaveMainHandlers: [UUID: () -> Void] = [:]
    /// Clears the shared main conversation once, however many workspaces are mounted.
    var leaveMain: () -> Void = {}
    /// Main-window actions a detached chat reaches: the quota page, and a new chat at a
    /// worktree carrying the detached composer's draft.
    var showQuota: () -> Void = {}
    var openMainChat: (_ projectPath: String, _ draft: String) -> Void = { _, _ in }

    init(makeWindow: @escaping (QuickDestination) -> ConversationWindowHandle = ConversationWindowStore.unconfigured) {
        self.makeWindow = makeWindow
    }

    nonisolated private static func unconfigured(_: QuickDestination) -> ConversationWindowHandle {
        preconditionFailure("ConversationWindowStore.makeWindow is not configured")
    }

    var windowCount: Int { windows.count }

    func addLeaveMainHandler(_ id: UUID, _ handler: @escaping () -> Void) { leaveMainHandlers[id] = handler }
    func removeLeaveMainHandler(_ id: UUID) { leaveMainHandlers[id] = nil }

    func open(_ destination: QuickDestination) {
        guard let id = destination.sessionID else { return }
        // A room shown on the Bots page leaves it when its id joins `detachedSessionIDs`.
        switch Self.resolve(
            sessionID: id, mainSessionID: mainSessionID(), columnSessionIDs: columnSessionIDs(),
            detachedSessionIDs: detachedSessionIDs)
        {
        case .focusWindow:
            focus(sessionID: id)
        case .openWindow(let leaveMain, let removeFromColumn):
            if leaveMain {
                self.leaveMain()
                for handler in leaveMainHandlers.values { handler() }
            }
            if removeFromColumn { self.removeFromColumn(id) }
            let window = makeWindow(destination)
            windows[id] = window
            detachedSessionIDs.insert(id)
            window.focus()
        }
    }

    @discardableResult
    func focus(sessionID: String) -> Bool {
        guard let window = windows[sessionID] else { return false }
        window.focus()
        return true
    }

    /// The window closed itself; forget it without closing it again.
    func windowDidClose(sessionID: String) {
        windows[sessionID] = nil
        detachedSessionIDs.remove(sessionID)
    }

    /// Closes a detached window, for example before its session is deleted.
    func close(sessionID: String) {
        guard let window = windows.removeValue(forKey: sessionID) else { return }
        detachedSessionIDs.remove(sessionID)
        window.close()
    }

    /// Keeps titles in step with renames. Session lists are profile-scoped, so a
    /// window whose session is missing from this list is left alone.
    func retitle(from sessions: [HermesSession]) {
        guard !windows.isEmpty else { return }
        for session in sessions { windows[session.id]?.retitle(session.displayTitle) }
    }

    nonisolated static func resolve(
        sessionID: String, mainSessionID: String?, columnSessionIDs: Set<String>, detachedSessionIDs: Set<String>
    ) -> ConversationWindowResolution {
        if detachedSessionIDs.contains(sessionID) { return .focusWindow }
        // Closing a split tab already moves the main conversation on when that tab was active.
        if columnSessionIDs.contains(sessionID) { return .openWindow(leaveMain: false, removeFromColumn: true) }
        return .openWindow(leaveMain: sessionID == mainSessionID, removeFromColumn: false)
    }

    /// A remembered frame is reused while at least half of it is on a connected screen;
    /// otherwise the window opens centered on the pointer's screen, cascading per open window.
    nonisolated static func placement(
        saved: CGRect?, screens: [CGRect], mouse: CGPoint, size: CGSize, cascadeIndex: Int
    ) -> CGRect {
        if let saved, saved.width > 0, saved.height > 0 {
            let visible = screens.reduce(CGFloat(0)) { area, screen in
                let overlap = screen.intersection(saved)
                return area + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            if visible >= saved.width * saved.height / 2 { return saved }
        }
        let wanted = saved.map(\.size) ?? size
        guard let screen = screens.first(where: { $0.contains(mouse) }) ?? screens.first else {
            return CGRect(origin: .zero, size: wanted)
        }
        let size = CGSize(width: min(wanted.width, screen.width), height: min(wanted.height, screen.height))
        let step = cascadeStep * CGFloat(cascadeIndex)
        var origin = CGPoint(x: screen.midX - size.width / 2 + step, y: screen.midY - size.height / 2 - step)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}
