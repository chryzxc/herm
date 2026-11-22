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
    private var current = DockMotionBudget()
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private var sessionInactive = false

    /// While hidden, each read re-checks AppKit, so a missed occlusion notification
    /// can't freeze every clock at the hidden recheck rate.
    var budget: DockMotionBudget {
        if !current.visible { refresh() }
        return current
    }

    private init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { DockMotionBudgetMonitor.shared.refresh() }
            })
        // Screen sleep and session switches are tracked apart: waking the screens
        // must not clear an inactive session, or the reverse.
        let workspace: [(Notification.Name, Signal)] = [
            (NSWorkspace.screensDidSleepNotification, .screensAsleep(true)),
            (NSWorkspace.screensDidWakeNotification, .screensAsleep(false)),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive(true)),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive(false)),
        ]
        for (name, signal) in workspace {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { DockMotionBudgetMonitor.shared.apply(signal) }
                })
        }
        refresh()
    }

    private enum Signal: Sendable {
        case screensAsleep(Bool)
        case sessionInactive(Bool)
    }

    private func apply(_ signal: Signal) {
        switch signal {
        case .screensAsleep(let asleep): screensAsleep = asleep
        case .sessionInactive(let inactive): sessionInactive = inactive
        }
        refresh()
    }

    private func refresh() {
        // NSApp is nil in unit tests that render before any app exists.
        let onScreen = NSApp.map { $0.occlusionState.contains(.visible) } ?? true
        current = DockMotionBudget(visible: !screensAsleep && !sessionInactive && onScreen)
    }
}
