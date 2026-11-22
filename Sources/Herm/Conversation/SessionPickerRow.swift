import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Rows sliding under a still pointer otherwise flip hover on every row they
/// pass, each building and tearing down its action buttons. Like Finder, hover
/// pauses while the list scrolls. `content` is stored, not a closure, so the
/// scroll-phase flip does not rebuild the rail or the transcript's rows.
/// Without it SwiftUI re-hit-tests every hover region on each scroll frame
/// (`EventBindingManager.enqueueHoverUpdateIfNeeded`), even with the pointer still.
struct HoverPausingScrollView<Content: View>: View {
    let content: Content
    private let usesAppKitScrollPhase: Bool
    @State private var isScrolling = false

    init(usesAppKitScrollPhase: Bool = false, @ViewBuilder content: () -> Content) {
        self.usesAppKitScrollPhase = usesAppKitScrollPhase
        self.content = content()
    }

    var body: some View {
        if #available(macOS 15, *), !usesAppKitScrollPhase {
            ScrollView { content.allowsHitTesting(!isScrolling) }
                .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        } else {
            ScrollView {
                content.allowsHitTesting(!isScrolling).background {
                    AppKitScrollPhaseObserver(onPhase: { isScrolling = $0 }).allowsHitTesting(false)
                }
            }
            .onDisappear { isScrolling = false }
        }
    }
}

struct AppKitScrollPhaseObserver: NSViewRepresentable {
    let onPhase: (Bool) -> Void
    final class Probe: NSView {
        var onPhase: ((Bool) -> Void)?
        private var tracking = false
        private weak var scroll: NSScrollView?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bind()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            bind()
        }
        private func bind() {
            let next = window == nil ? nil : enclosingScrollView
            guard scroll !== next else { return }
            if let scroll {
                for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                    NotificationCenter.default.removeObserver(self, name: name, object: scroll)
                }
            }
            if tracking {
                tracking = false
                Task { @MainActor [weak self] in
                    guard let self, !tracking else { return }
                    onPhase?(false)
                }
            }
            scroll = next
            guard let next else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(start), name: NSScrollView.willStartLiveScrollNotification, object: next)
            NotificationCenter.default.addObserver(
                self, selector: #selector(end), name: NSScrollView.didEndLiveScrollNotification, object: next)
        }
        @objc private func start(_ note: Notification) {
            tracking = true
            onPhase?(true)
        }
        @objc private func end(_ note: Notification) {
            tracking = false
            onPhase?(false)
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.onPhase = onPhase }
}

/// Sweeps an accent highlight across a working session's title. Static under
/// Reduce Motion; only working rows pay for the timeline.
struct WorkingTitleShimmer: ViewModifier {
    let isActive: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content.overlay {
                DockLayerMotion(kind: .sweep(period: 2.2, fraction: 0.4, clamp: 40...(.infinity)), color: color)
                    .mask(content)
                    .allowsHitTesting(false)
            }
        } else if isActive {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}
