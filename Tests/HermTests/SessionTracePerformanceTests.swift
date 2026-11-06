import AppKit
import Combine
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionTracePerformanceTests {
    @Test func pixelMovementPublishesOnlyWhenBufferedRowsChange() {
        let viewport = SessionTraceRowViewport()
        let host = NSView()
        var updates = 0
        let subscription = viewport.rowWindow.$range.dropFirst().sink { _ in updates += 1 }
        for offset in 1...5 {
            viewport.update(host: host, rect: CGRect(x: 0, y: CGFloat(offset), width: 1, height: 360))
        }
        #expect(viewport.visibleRect.minY == 5)
        #expect(updates == 0)
        viewport.update(host: host, rect: CGRect(x: 0, y: 35, width: 1, height: 360))
        #expect(updates == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test func traceVisibilityStaysActiveWhileAnExpandedWindowIsVisible() {
        let visibility = SessionTraceWindowVisibility()
        let inspector = UUID()
        let expanded = UUID()
        visibility.update(inspector, visible: false)
        #expect(!visibility.isVisible)
        visibility.update(expanded, visible: true)
        #expect(visibility.isVisible)
        visibility.update(expanded, visible: nil)
        #expect(!visibility.isVisible)
        visibility.update(inspector, visible: nil)
        #expect(visibility.isVisible)
    }

    @Test func preparationReusesUnchangedHistoryAndRebuildsForChanges() {
        let start = Date(timeIntervalSince1970: 1_000)
        var turn = SessionTraceTurn(
            id: "one", title: "Request", start: start,
            rows: [.init(id: "root", kind: .turn, title: "Request", start: start, timing: .runtime)])
        let cache = SessionTracePreparationCache()
        #expect(cache.prepare(turn).lanes.lanes.count == 1)
        for _ in 0..<20 { _ = cache.prepare(turn) }
        #expect(cache.buildCount == 1)
        turn.rows.append(.init(id: "tool", parentID: "root", kind: .tool, title: "Tool", timing: .unavailable))
        #expect(cache.prepare(turn).crew.ownerByRow["tool"] == "root")
        #expect(cache.buildCount == 2)
    }

    final class Evaluations {
        var labels = 0
        var bars = 0
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SCROLL_PROFILE"] == "1"))
    func profileTimelineScrolling() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let rows = (0..<1_000).map { index in
            SessionTraceRow(
                id: "row-\(index)", kind: .tool, title: "Tool \(index)",
                start: start.addingTimeInterval(Double(index)), duration: 1, timing: .runtime)
        }
        let host = NSHostingView(
            rootView: SessionTraceCanvas(
                turns: [.init(id: "profile", title: "Profile", start: start, rows: rows)], connected: false))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        func observer(_ view: NSView) -> SessionTraceViewportObserver.Observer? {
            (view as? SessionTraceViewportObserver.Observer) ?? view.subviews.lazy.compactMap(observer).first
        }
        let viewport = try #require(observer(host)).viewport
        let cpuStart = mainThreadCPUMilliseconds()
        var timings: [Double] = []
        for step in 0..<120 {
            let started = DispatchTime.now().uptimeNanoseconds
            viewport.scroll(to: step < 60 ? step * 4 : (120 - step) * 4, centered: true)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            try await Task.sleep(for: .milliseconds(8))
        }
        let cpu = mainThreadCPUMilliseconds() - cpuStart
        let sorted = timings.sorted()
        print(
            "timeline_scroll p50_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)]) max_ms=\(sorted.last ?? 0) main_cpu_ms=\(cpu)"
        )
    }

    @Test func longTimelinePreparesOnlyNearbyRows() async throws {
        #if DEBUG
            let start = Date(timeIntervalSince1970: 1_000)
            let rows = (0..<1_000).map { index in
                SessionTraceRow(
                    id: "row-\(index)", kind: .tool, title: "Tool \(index)",
                    start: start.addingTimeInterval(Double(index)), duration: 1, timing: .runtime)
            }
            let evaluations = Evaluations()
            let root = SessionTraceCanvas(
                turns: [.init(id: "long", title: "Long request", start: start, rows: rows)],
                connected: true
            )
            .environment(\.conversationRowEvaluation) { name, _ in
                if name == "timeline-label" { evaluations.labels += 1 }
                if name == "timeline-bar" { evaluations.bars += 1 }
            }
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            print("timeline_rows labels=\(evaluations.labels) bars=\(evaluations.bars)")
            #expect(evaluations.labels > 0 && evaluations.labels < 200)
            #expect(evaluations.bars > 0 && evaluations.bars < 200)
            func observer(_ view: NSView) -> SessionTraceViewportObserver.Observer? {
                (view as? SessionTraceViewportObserver.Observer) ?? view.subviews.lazy.compactMap(observer).first
            }
            let viewport = try #require(observer(host)).viewport
            #expect(SessionTraceRowViewport.range(count: rows.count, rect: viewport.visibleRect).contains(999))
            for index in [0, 500, 999] {
                evaluations.labels = 0
                evaluations.bars = 0
                viewport.scroll(to: index, centered: true)
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                #expect(SessionTraceRowViewport.range(count: rows.count, rect: viewport.visibleRect).contains(index))
                #expect(evaluations.labels < 200 && evaluations.bars < 200)
            }
        #endif
    }

    @Test func liveUpdatesDoNotRescanCompletedHistory() {
        let model = DockModel(initialSessionID: "timeline-performance")
        model.messages = (0..<500).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .hermes, text: "Message \(index)")
        }
        let trace = SessionTraceModel()
        trace.update(model)
        let before = trace.historyScanCount
        for index in 0..<5 {
            model.streamingTurnActivity.append(
                ActiveToolCall(
                    id: "call-\(index)", name: "terminal",
                    input: "Synthetic tool", context: "", startedAt: Date(), isComplete: false))
            trace.update(model)
        }
        #expect(trace.historyScanCount == before)
        #expect(trace.turns.last?.toolCount == 5)
        model.messages.insert(ChatMessage(role: .user, text: "Prepended history"), at: 0)
        trace.update(model)
        #expect(trace.historyScanCount == before + 1)
        #expect(trace.turns.first?.title == "Prepended history")
    }

    @Test func horizontalNavigationKeepsLabelsStaticAndBarWorkBounded() async throws {
        #if DEBUG
            let start = Date().addingTimeInterval(-8_000)
            let rows = (0..<1_000).map { index in
                SessionTraceRow(
                    id: "row-\(index)", kind: .tool, title: "Tool \(index)",
                    start: start.addingTimeInterval(Double(index) * 8), duration: 1,
                    timing: .runtime, active: index == 999)
            }
            let evaluations = Evaluations()
            let root = SessionTraceCanvas(
                turns: [.init(id: "long", title: "Long request", start: start, rows: rows)],
                connected: false, isVisible: false
            )
            .environment(\.conversationRowEvaluation) { name, _ in
                if name == "timeline-label" { evaluations.labels += 1 }
                if name == "timeline-bar" { evaluations.bars += 1 }
            }
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            func horizontal(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView,
                    (scroll.documentView?.bounds.width ?? 0) > scroll.contentView.bounds.width
                {
                    return scroll
                }
                return view.subviews.lazy.compactMap(horizontal).first
            }
            let scroll = try #require(horizontal(host))
            for x in [0.0, 40_000, 90_000] {
                evaluations.labels = 0
                evaluations.bars = 0
                scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                #expect(evaluations.labels == 0)
                #expect(evaluations.bars > 0 && evaluations.bars < 200)
            }
        #endif
    }

    @Test func subscriptionsIgnoreUnrelatedUpdatesAndCancelWhileHidden() async throws {
        let model = DockModel(initialSessionID: "timeline-subscriptions")
        model.messages = [ChatMessage(role: .user, text: "Request")]
        let trace = SessionTraceModel()
        trace.observe(model)
        let before = trace.updateCount
        for index in 0..<100 {
            model.isLoadingSessions.toggle()
            model.botLiveSteps["background"] = "Step \(index)"
            model.streamingText.appendPresentation("Chunk \(index)")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(trace.updateCount == before)
        model.activeToolCalls = [
            ActiveToolCall(
                id: "live", name: "terminal", input: "Synthetic tool",
                context: "", startedAt: Date(), isComplete: false)
        ]
        for _ in 0..<100 where trace.turns.last?.toolCount != 1 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(trace.turns.last?.toolCount == 1)
        let updated = trace.updateCount
        model.activityPresentationRevision &+= 1
        trace.suspend()
        model.messages.append(ChatMessage(role: .user, text: "While hidden"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(trace.updateCount == updated)
        trace.observe(model)
        #expect(trace.turns.last?.title == "While hidden")
        trace.suspend()
    }

    @Test func clockBoundsMatchFullRowCalculationAndWindowRangesStayBounded() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let turn = SessionTraceTurn(
            id: "t", title: "T", start: origin,
            rows: [
                SessionTraceRow(id: "done", kind: .tool, title: "Done", start: origin, duration: 30, timing: .runtime),
                SessionTraceRow(
                    id: "live", kind: .agent, title: "Live", start: origin.addingTimeInterval(5),
                    timing: .observed, active: true, shift: 10),
            ])
        let bounds = SessionTraceTimeBounds(turn)
        for offset in [0.0, 20, 100] {
            let now = origin.addingTimeInterval(offset)
            let finish = turn.rows.compactMap { $0.finish(at: now) }.max() ?? origin
            #expect(bounds.span(at: now) == max(1, finish.timeIntervalSince(origin)))
        }
        for top in [-100.0, 0, 17_000, 33_900] {
            let range = SessionTraceRowViewport.range(
                count: 1_000,
                rect: CGRect(x: 0, y: top, width: 760, height: 360))
            #expect(range.count <= 34 && range.lowerBound >= 0 && range.upperBound <= 1_000)
        }
        #expect(SessionTraceRowViewport.range(count: 0, rect: .zero).isEmpty)
    }
}
