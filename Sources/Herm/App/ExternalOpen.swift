import AppKit

/// Herm's panels float at status-bar level, which would hide Finder or
/// browser windows opened from inside Herm. These helpers drop the panels to
/// normal level while the other app is in front, and restore them on the
/// next click or keypress in Herm (or when Herm becomes active again).
@MainActor
enum ExternalOpen {
    private static var savedLevels: [(NSWindow, NSWindow.Level)] = []
    private static var monitor: Any?
    private static var activeObserver: NSObjectProtocol?

    nonisolated static func open(_ url: URL) {
        onMain {
            yieldToOtherApp()
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func reveal(_ urls: [URL]) {
        onMain {
            yieldToOtherApp()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async(execute: work) }
    }

    private static func yieldToOtherApp() {
        if savedLevels.isEmpty {
            savedLevels = NSApp.windows.compactMap { $0 is DockPanel && $0.level > .normal ? ($0, $0.level) : nil }
        }
        guard !savedLevels.isEmpty else { return }
        savedLevels.forEach { $0.0.level = .normal }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            restore()
            return event
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { restore() } }
    }

    private static func restore() {
        savedLevels.forEach { $0.0.level = $0.1 }
        savedLevels = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        monitor = nil
        activeObserver = nil
    }
}
