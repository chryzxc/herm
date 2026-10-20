import AppKit
import SwiftUI

/// Presentation only. The underlying workspace stays mounted, retaining drafts and scroll anchors.
@MainActor
final class ExpandedReviewRouter: ObservableObject {
    @MainActor final class Layer: Identifiable {
        let id = UUID()
        let content: AnyView
        weak var responder: NSResponder?
        weak var window: NSWindow?
        init(content: AnyView, window: NSWindow?) {
            self.content = content
            self.window = window
            responder = window?.firstResponder
        }
    }
    @Published private(set) var layers: [Layer] = []
    var content: AnyView? { layers.last?.content }
    var availableWidth: CGFloat = 0
    weak var window: NSWindow?
    private var focusGeneration = UUID()

    @discardableResult
    func present<Content: View>(_ view: Content) -> Bool {
        guard availableWidth >= 800 else { return false }
        let window = window ?? NSApp.keyWindow
        focusGeneration = UUID()
        layers.append(Layer(content: AnyView(view), window: window))
        window?.makeFirstResponder(nil)
        return true
    }
    func close(restoreFocus: Bool = true) {
        guard let layer = layers.popLast() else { return }
        focusGeneration = UUID()
        let generation = focusGeneration
        guard restoreFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard self?.focusGeneration == generation, let responder = layer.responder else { return }
            layer.window?.makeFirstResponder(responder)
        }
    }
    func closeAll(restoreFocus: Bool = true) {
        while !layers.isEmpty { close(restoreFocus: restoreFocus) }
    }

}

private struct ExpandedReviewRouterKey: EnvironmentKey {
    static let defaultValue: ExpandedReviewRouter? = nil
}
extension EnvironmentValues {
    var expandedReviewRouter: ExpandedReviewRouter? {
        get { self[ExpandedReviewRouterKey.self] }
        set { self[ExpandedReviewRouterKey.self] = newValue }
    }
}

/// Modal reviews must not route into a workspace behind their presenting sheet.
struct ReviewSheetContext: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.expandedReviewRouter, nil).environment(\.dockTitleRow, nil)
    }
}

struct ObservedReviewRequest: Identifiable {
    let id = UUID()
    let session: HermesSession
    let path: String
    let comparison: ObservedRequestComparison?
}

struct ExpandedReviewHost: ViewModifier {
    @ObservedObject var model: DockModel
    @ObservedObject private var observed = ObservedRequestChanges.shared
    @State private var pendingReview: ObservedReviewRequest?
    @State private var deferredReview: ObservedReviewRequest?
    @ObservedObject var router: ExpandedReviewRouter
    var titleRow: DockTitleRow? = nil
    func body(content: Content) -> some View {
        content
            .environment(\.localPreviewDiscoveryVisible, router.layers.isEmpty)
            .disabled(router.content != nil)
            .allowsHitTesting(router.content == nil)
            .accessibilityHidden(router.content != nil)
            .overlay {
                ZStack {
                    ForEach(router.layers) { layer in
                        layer.content.environment(\.dockTitleRow, titleRow).background(DockPaneBackground())
                            .opacity(layer.id == router.layers.last?.id ? 1 : 0)
                            .disabled(layer.id != router.layers.last?.id)
                            .allowsHitTesting(layer.id == router.layers.last?.id)
                            .accessibilityHidden(layer.id != router.layers.last?.id)
                    }
                }
            }
            .background(
                ReviewWindowProbe { window in
                    router.window = window
                    if router.availableWidth == 0 { router.availableWidth = window?.contentView?.bounds.width ?? 0 }
                    if let deferredReview { Task { @MainActor in presentRequest(deferredReview) } }
                }
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { router.availableWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in router.availableWidth = width }
                }
            }
            .environment(\.expandedReviewRouter, router)
            .onReceive(observed.$requestedReview) { request in
                guard let request else { return }
                Task { @MainActor in
                    guard observed.requestedReview?.id == request.id else { return }
                    observed.requestedReview = nil
                    presentRequest(request)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
                guard note.object as? NSWindow === router.window, let deferredReview else { return }
                Task { @MainActor in presentRequest(deferredReview) }
            }
            .sheet(item: $pendingReview) { request in
                review(request, close: { pendingReview = nil }).modifier(ReviewSheetContext())
            }
    }
    private func presentRequest(_ request: ObservedReviewRequest) {
        guard let window = router.window, window.attachedSheet == nil else {
            deferredReview = request
            return
        }
        deferredReview = nil
        if !router.present(review(request, close: { router.close() })) { pendingReview = request }
    }

    @ViewBuilder private func review(_ request: ObservedReviewRequest, close: @escaping () -> Void) -> some View {
        if let comparison = request.comparison {
            ObservedRequestReview(closeAction: close, comparison: comparison)
        } else {
            LocalReviewWorkspace(owningSession: request.session, closeAction: close, path: request.path, model: model)
        }
    }

}

private struct ReviewWindowProbe: NSViewRepresentable {
    let changed: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Probe { Probe(changed: changed) }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed }
    final class Probe: NSView {
        var changed: (NSWindow?) -> Void
        init(changed: @escaping (NSWindow?) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            changed(window)
        }
    }
}
