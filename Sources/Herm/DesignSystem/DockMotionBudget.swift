import AppKit

/// Whether decorative motion has anyone to show it to. Every
/// `DockMotionSchedule` tick re-renders its window, and live surfaces (the
/// notch, working Bot faces) keep ticking while Herm sits in the background,
/// including with the screen locked or asleep. When no Herm window is on
/// screen the clock holds, re-checking once a second so motion resumes when a
/// window returns. Visible motion always keeps its full rate.
struct DockMotionBudget: Equatable {
    var visible = true

    static let hiddenRecheck: TimeInterval = 1

    /// Seconds the clock holds before its next tick; 0 when it may tick.
    var hold: TimeInterval { visible ? 0 : Self.hiddenRecheck }
}

/// The live budget, refreshed from AppKit and workspace notifications instead
/// of being queried on every tick.
@MainActor
final class DockMotionBudgetMonitor {
    static let shared = DockMotionBudgetMonitor()
    private(set) var budget = DockMotionBudget()
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false

    private init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { DockMotionBudgetMonitor.shared.refresh() }
            })
        let workspace: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, asleep) in workspace {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { DockMotionBudgetMonitor.shared.refresh(screensAsleep: asleep) }
                })
        }
        refresh()
    }

    private func refresh(screensAsleep asleep: Bool? = nil) {
        if let asleep { screensAsleep = asleep }
        // NSApp is nil in unit tests that render before any app exists.
        let onScreen = NSApp.map { $0.occlusionState.contains(.visible) } ?? true
        budget = DockMotionBudget(visible: !screensAsleep && onScreen)
    }
}
