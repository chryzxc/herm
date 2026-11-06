import AppKit
import Combine
import SwiftUI

/// Tracks each window that presents a trace, including its expanded sheet.
@MainActor
final class SessionTraceWindowVisibility: ObservableObject {
    @Published private(set) var isVisible = true
    private var windows: [UUID: Bool] = [:]

    func update(_ id: UUID, visible: Bool?) {
        windows[id] = visible
        let next = windows.isEmpty || windows.values.contains(true)
        if isVisible != next { isVisible = next }
    }
}

struct SessionTraceWindowVisibilityObserver: NSViewRepresentable {
    let visibility: SessionTraceWindowVisibility

    func makeNSView(context: Context) -> Observer { Observer(visibility: visibility) }
    func updateNSView(_ view: Observer, context: Context) {}
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: NSView {
        private let id = UUID()
        private let visibility: SessionTraceWindowVisibility
        private var notifications: [NSObjectProtocol] = []
        private var generation = 0

        init(visibility: SessionTraceWindowVisibility) {
            self.visibility = visibility
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            ] {
                notifications.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleUpdate() }
                    })
            }
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == token, let window else { return }
                visibility.update(
                    id, visible: window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
            }
        }

        func stop() {
            generation += 1
            for notification in notifications { NotificationCenter.default.removeObserver(notification) }
            notifications = []
            visibility.update(id, visible: nil)
        }
    }
}
