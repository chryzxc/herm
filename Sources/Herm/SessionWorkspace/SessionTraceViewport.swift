import AppKit
import SwiftUI

/// Shared by drawing and navigation so short steps keep the same minimum hit width.
struct SessionTraceBarLayout {
    enum Offscreen { case earlier, later }
    let x: CGFloat
    let width: CGFloat

    init(offset: TimeInterval, elapsed: TimeInterval, scale: CGFloat, contentWidth: CGFloat) {
        x = min(contentWidth, max(0, offset * scale))
        width = min(max(4, contentWidth - x), max(4, elapsed * scale))
    }

    func offscreen(in viewport: CGRect) -> Offscreen? {
        if x + width <= viewport.minX { return .earlier }
        if x >= viewport.maxX { return .later }
        return nil
    }

    func revealOffset(in viewport: CGRect, contentWidth: CGFloat) -> CGFloat? {
        guard offscreen(in: viewport) != nil else { return nil }
        return min(max(0, x - 12), max(0, contentWidth - viewport.width))
    }
}

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

/// Reuses the expensive ownership and time indexes until the trace changes.
@MainActor
final class SessionTracePreparationCache {
    struct Prepared {
        let crew: SessionCrewProjection
        let lanes: SessionActivityLanes
        let bounds: SessionTraceTimeBounds
        let toolGeometry: SessionActivityToolGeometry
    }

    private var previous: SessionTraceTurn?
    private var cached: Prepared?
    private(set) var buildCount = 0

    func prepare(_ turn: SessionTraceTurn) -> Prepared {
        if previous == turn, let cached { return cached }
        let crew = SessionCrewProjection(rows: turn.rows)
        let lanes = SessionActivityLanes(crew)
        let bounds = SessionTraceTimeBounds(turn)
        let prepared = Prepared(
            crew: crew, lanes: lanes, bounds: bounds,
            toolGeometry: SessionActivityToolGeometry(lanes: lanes, origin: bounds.origin))
        previous = turn
        cached = prepared
        buildCount += 1
        return prepared
    }
}

/// Fixed-height Timeline rows can keep their full extent without preparing every label and bar.
@MainActor
final class SessionTraceRowWindowState: ObservableObject {
    @Published private(set) var range: Range<Int>

    init(rect: CGRect) {
        range = SessionTraceRowViewport.range(count: Int.max, rect: rect)
    }

    func update(rect: CGRect) {
        let next = SessionTraceRowViewport.range(count: Int.max, rect: rect)
        if range != next { range = next }
    }
}

@MainActor
final class SessionTraceRowViewport: ObservableObject {
    static let rowHeight: CGFloat = 34
    @Published private(set) var visibleRect = CGRect(x: 0, y: 0, width: 1, height: 360)
    let rowWindow = SessionTraceRowWindowState(rect: CGRect(x: 0, y: 0, width: 1, height: 360))
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
        rowWindow.update(rect: rect)
        if visibleRect != rect { visibleRect = rect }
    }

    func scroll(to index: Int, centered: Bool) {
        guard let host, let scroll = host.enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let target = (CGFloat(index) + (centered ? 0.5 : 1)) * Self.rowHeight
        let y = target - clip.bounds.height * (centered ? 0.5 : 1)
        let point = host.convert(NSPoint(x: 0, y: max(0, y)), to: document)
        let origin = document.isFlipped ? point.y : point.y - clip.bounds.height
        clip.scroll(
            to: NSPoint(x: clip.bounds.minX, y: max(0, min(origin, document.bounds.height - clip.bounds.height))))
        scroll.reflectScrolledClipView(clip)
    }
}

struct SessionTraceRowWindow<Content: View>: View {
    @ObservedObject var viewport: SessionTraceRowWindowState
    let items: [(row: SessionTraceRow, depth: Int)]
    @ViewBuilder let content: (SessionTraceRow, Int) -> Content
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    var body: some View {
        let lower = min(items.count, viewport.range.lowerBound)
        let upper = min(items.count, viewport.range.upperBound)
        let range = voiceOver || switchControl || NSApp.isFullKeyboardAccessEnabled ? items.indices : lower..<upper
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
        init(viewport: SessionTraceRowViewport) {
            self.viewport = viewport
            super.init(frame: .zero)
        }
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
        override func layout() {
            super.layout()
            report()
        }
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
