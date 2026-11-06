import AppKit
import SwiftUI

@MainActor
final class DockPresentationDemand: ObservableObject {
    @Published private(set) var hasVisibleHost = false
    private var visibleHosts = Set<UUID>()

    func update(_ id: UUID, visible: Bool) {
        if visible { visibleHosts.insert(id) } else { visibleHosts.remove(id) }
        let next = !visibleHosts.isEmpty
        if hasVisibleHost != next { hasVisibleHost = next }
    }
}

@MainActor
final class DockHostPresentation: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var isResizing = false
    private var displaysAsleep = false

    func setDisplaysAsleep(_ asleep: Bool, window: NSWindow?) {
        displaysAsleep = asleep
        update(window: window)
    }

    func update(window: NSWindow?) {
        let visible =
            !displaysAsleep
            && (window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
        let resizing = window?.inLiveResize ?? false
        if isVisible != visible { isVisible = visible }
        if isResizing != resizing { isResizing = resizing }
    }
}

private struct DockHostVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct DockHostResizingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var dockHostVisible: Bool {
        get { self[DockHostVisibleKey.self] }
        set { self[DockHostVisibleKey.self] = newValue }
    }
    var dockHostResizing: Bool {
        get { self[DockHostResizingKey.self] }
        set { self[DockHostResizingKey.self] = newValue }
    }
}

struct DockHostPresentationObserver: NSViewRepresentable {
    let presentation: DockHostPresentation
    func makeNSView(context: Context) -> Observer { Observer(presentation: presentation) }
    func updateNSView(_ view: Observer, context: Context) {}
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: NSView {
        private let presentation: DockHostPresentation
        private var observers: [NSObjectProtocol] = []
        private var workspaceObservers: [NSObjectProtocol] = []
        private var generation = 0

        init(presentation: DockHostPresentation) {
            self.presentation = presentation
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
                NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in MainActor.assumeIsolated { self?.scheduleUpdate() }
                    })
            }
            for (name, asleep) in [
                (NSWorkspace.screensDidSleepNotification, true),
                (NSWorkspace.screensDidWakeNotification, false),
            ] {
                workspaceObservers.append(
                    NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.presentation.setDisplaysAsleep(asleep, window: self.window)
                        }
                    })
            }
            scheduleUpdate()
        }
        private func scheduleUpdate() {
            let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == token else { return }
                presentation.update(window: window)
            }
        }
        func stop() {
            generation += 1
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            workspaceObservers.removeAll()
            let presentation = presentation
            DispatchQueue.main.async { presentation.update(window: nil) }
        }
    }
}
