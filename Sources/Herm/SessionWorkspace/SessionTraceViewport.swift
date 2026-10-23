import AppKit
import SwiftUI

/// Resolve the full row set once per projection, never once per clock tick.
struct SessionTraceTimeBounds {
    let origin: Date
    let finish: Date
    let activeShift: TimeInterval?
    let hasTimedActivity: Bool
    let hasTiming: Bool

    init(_ turn: SessionTraceTurn) {
        origin = turn.rows.compactMap(\.start).min() ?? turn.start
        finish = turn.rows.filter { !$0.active }.compactMap { $0.finish(at: turn.start) }.max() ?? origin
        activeShift = turn.rows.filter(\.active).map(\.shift).min()
        hasTimedActivity = turn.rows.contains { $0.active && $0.start != nil }
        hasTiming = turn.rows.contains { $0.start != nil }
    }

    func span(at now: Date) -> TimeInterval {
        let latest = activeShift.map { max(finish, now.addingTimeInterval(-$0)) } ?? finish
        return max(1, latest.timeIntervalSince(origin))
    }
}

/// Fixed-height Timeline rows can keep their full extent without preparing every label and bar.
@MainActor
final class SessionTraceRowViewport: ObservableObject {
    static let rowHeight: CGFloat = 34
    @Published private(set) var visibleRect = CGRect(x: 0, y: 0, width: 1, height: 360)
    private weak var host: NSView?

    static func range(count: Int, rect: CGRect) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let height = max(rowHeight, rect.height)
        let first = min(count, max(0, Int(floor((rect.minY - height) / rowHeight))))
        let last = max(first, min(count, Int(ceil((rect.maxY + height) / rowHeight))))
        return first..<last
    }

    func update(host: NSView, rect: CGRect) {
        self.host = host
        if visibleRect != rect { visibleRect = rect }
    }

    func scroll(to index: Int, centered: Bool) {
        guard let host, let scroll = host.enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let target = (CGFloat(index) + (centered ? 0.5 : 1)) * Self.rowHeight
        let y = target - clip.bounds.height * (centered ? 0.5 : 1)
        let point = host.convert(NSPoint(x: 0, y: max(0, y)), to: document)
        let origin = document.isFlipped ? point.y : point.y - clip.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, min(origin, document.bounds.height - clip.bounds.height))))
        scroll.reflectScrolledClipView(clip)
    }
}

struct SessionTraceRowWindow<Content: View>: View {
    @ObservedObject var viewport: SessionTraceRowViewport
    let items: [(row: SessionTraceRow, depth: Int)]
    @ViewBuilder let content: (SessionTraceRow, Int) -> Content
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    var body: some View {
        let range = voiceOver || switchControl || NSApp.isFullKeyboardAccessEnabled
            ? items.indices : SessionTraceRowViewport.range(count: items.count, rect: viewport.visibleRect)
        VStack(spacing: 0) {
            Color.clear.frame(height: CGFloat(range.lowerBound) * SessionTraceRowViewport.rowHeight)
            ForEach(items[range], id: \.row.id) { item in content(item.row, item.depth) }
            Color.clear.frame(height: CGFloat(items.count - range.upperBound) * SessionTraceRowViewport.rowHeight)
        }
    }
}

struct SessionTraceViewportObserver: NSViewRepresentable {
    let viewport: SessionTraceRowViewport
    func makeNSView(context: Context) -> Observer { Observer(viewport: viewport) }
    func updateNSView(_ view: Observer, context: Context) { view.viewport = viewport }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: NSView {
        var viewport: SessionTraceRowViewport
        private var notification: NSObjectProtocol?
        private var pending = false
        private var generation = 0
        override var isFlipped: Bool { true }
        init(viewport: SessionTraceRowViewport) { self.viewport = viewport; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            notification = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
            report()
        }
        override func layout() { super.layout(); report() }
        private func report() {
            guard !pending, window != nil else { return }
            pending = true
            let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.pending = false
                guard self.window != nil, let clip = self.enclosingScrollView?.contentView else { return }
                self.viewport.update(host: self, rect: self.convert(clip.bounds, from: clip))
            }
        }
        func stop() {
            generation += 1
            pending = false
            if let notification { NotificationCenter.default.removeObserver(notification) }
            notification = nil
        }
    }
}

/// Keep the grid's drawing surface bounded in both axes, even in a long session.
struct SessionTracePlotViewport<Content: View>: View {
    @ObservedObject var scroll: SessionTraceScroll
    @ObservedObject var viewport: SessionTraceRowViewport
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content
    var body: some View {
        let y = max(0, min(height, viewport.visibleRect.minY))
        let visibleHeight = max(0, min(height - y, viewport.visibleRect.height))
        content(scroll.x, visibleHeight)
            .frame(width: width, height: visibleHeight)
            .offset(x: scroll.x, y: y)
    }
}
