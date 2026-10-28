import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionInspectorTabOrderTests {
    @Test func nativeHoverPreservesCompactTabGeometry() async throws {
        let tab = SessionInspectorTabItem(
            id: "preview", title: "The complete tab name", icon: .chatText, isSelected: false, select: {}, close: {})
        let host = NSHostingView(
            rootView: SessionInspectorTab(
                tab: tab, compact: true, drag: SessionInspectorTabDrag(workspace: "workspace", id: tab.id),
                reorder: { _ in false }, moveLeft: nil, moveRight: nil
            ).dockThemedRoot())
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 52)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await settle(host)
        let source = try #require(descendants(host).compactMap { $0 as? SessionInspectorTabDragView }.first)
        let hover = try #require(descendants(host).compactMap { $0 as? SessionInspectorTabHoverView }.first)
        let event = try mouse(.mouseMoved, at: .zero, in: window)
        #expect(source.bounds.width <= 32)
        hover.mouseEntered(with: event)
        source.mouseEntered(with: event)
        try await settle(host)
        #expect(source.bounds.width <= 32)
        let preview = try #require(source.draggingItem())
        #expect(abs(preview.draggingFrame.width - hover.bounds.width) < 1)
        #expect(abs(preview.draggingFrame.width - source.bounds.width) < 1)
        #expect(!window.dockHasInteractiveChildWindow)
        // Entering and leaving the native target never changes its footprint.
        source.mouseExited(with: event)
        try await settle(host)
        #expect(source.bounds.width <= 32)
        hover.mouseExited(with: event)
        try await settle(host)
        #expect(source.bounds.width <= 32)
    }

    @Test func nativeDragKeepsClicksSeparateAndLoadsThroughTheDropRepresentation() async throws {
        let source = RecordingTabDragView(frame: NSRect(x: 0, y: 0, width: 160, height: 32))
        source.payload = SessionInspectorTabDrag(workspace: "workspace", id: "one")
        var selections = 0
        source.select = { selections += 1 }
        let window = NSWindow(contentRect: source.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isMovableByWindowBackground = true
        window.contentView = source
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let frame = window.frame
        for (type, x) in [
            (NSEvent.EventType.leftMouseDown, 20.0), (.leftMouseDragged, 22),
            (.leftMouseDragged, 40), (.leftMouseDragged, 60), (.leftMouseUp, 60),
        ] {
            window.sendEvent(try mouse(type, at: NSPoint(x: x, y: 16), in: window))
        }
        #expect(source.starts == 1)
        #expect(selections == 0)
        #expect(window.frame == frame)
        let item = try #require(source.item?.item as? NSPasteboardItem)
        let data = try #require(item.data(forType: SessionInspectorTabDrag.pasteboardType))
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: SessionInspectorTabDrag.pasteboardType.rawValue, visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        let payload: SessionInspectorTabDrag = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: SessionInspectorTabDrag.self) { continuation.resume(with: $0) }
        }
        let order = SessionInspectorTabOrder()
        #expect(order.move(payload, to: "two", available: ["one", "two"], in: "workspace"))
        #expect(order.ordered(["one", "two"], in: "workspace") == ["two", "one"])
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try mouse(type, at: NSPoint(x: 20, y: 16), in: window))
        }
        #expect(selections == 1)
    }

    @Test func collapseUsesAvailableSpaceAndPreservesTheActiveLabelWhenPossible() {
        let titles = ["Timeline", "Browser", "Terminal", "Explorer"]
        let width = SessionInspectorTabLayout.fullWidth(titles: titles)
        #expect(
            SessionInspectorTabLayout.collapsedIndices(
                titles: titles, selectedIndex: 2, availableWidth: width
            ).isEmpty)
        let collapsed = SessionInspectorTabLayout.collapsedIndices(
            titles: titles, selectedIndex: 2, availableWidth: width - 10)
        #expect(collapsed.count == 1)
        #expect(!collapsed.contains(2))
        #expect(
            SessionInspectorTabLayout.collapsedIndices(
                titles: titles, selectedIndex: 2, availableWidth: 20) == Set(titles.indices))
    }

    @Test func overflowingStripKeepsAllTabsWhenTheyFitAndRevealsTheActiveTab() async throws {
        let state = TabStripFixtureState()
        let host = NSHostingView(rootView: TabStripFixture(state: state).dockThemedRoot())
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: state.width, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await settle(host)
        func sources() -> [SessionInspectorTabDragView] {
            descendants(host).compactMap { $0 as? SessionInspectorTabDragView }
        }
        #expect(sources().count == 12)
        #expect(sources().contains { $0.bounds.width > 32 })
        for view in sources() { #expect(host.bounds.contains(view.convert(view.bounds, to: host))) }
        let compact = try #require(sources().first { $0.bounds.width <= 32 })
        let origin = compact.convert(NSPoint.zero, to: host)
        compact.mouseEntered(with: try mouse(.mouseMoved, at: compact.convert(NSPoint.zero, to: nil), in: window))
        try await settle(host)
        #expect(compact.bounds.width <= 32)
        #expect(abs(compact.convert(NSPoint.zero, to: host).x - origin.x) < 1)
        state.width = 150
        state.selected = 11
        window.setContentSize(NSSize(width: state.width, height: 60))
        try await settle(host)
        let last = try #require(sources().first { $0.payload?.id == "11" })
        #expect(host.bounds.contains(last.convert(last.bounds, to: host)))
        state.selected = 0
        try await settle(host)
        let first = try #require(sources().first { $0.payload?.id == "0" })
        #expect(host.bounds.contains(first.convert(first.bounds, to: host)))
        state.width = SessionInspectorTabLayout.fullWidth(titles: state.titles) + 10
        window.setContentSize(NSSize(width: state.width, height: 60))
        try await settle(host)
        #expect(sources().allSatisfy { $0.bounds.width > 32 })
    }

    @Test func tabSelectionDoesNotOfferToDragTheWindow() async throws {
        var selections = 0
        let tab = SessionInspectorTabItem(
            id: "timeline", title: "Timeline", icon: .chartBarHorizontal, isSelected: true,
            select: { selections += 1 }, close: {})
        let host = NSHostingView(
            rootView: VStack {
                HStack {
                    Spacer()
                    SessionInspectorTab(
                        tab: tab, compact: false,
                        drag: SessionInspectorTabDrag(workspace: "workspace", id: tab.id),
                        reorder: { _ in false }, moveLeft: nil, moveRight: nil)
                }.frame(height: DockWindowChrome.titleRowHeight)
                Spacer()
            }.dockThemedRoot())
        host.safeAreaRegions = []
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "tab-drag-test")
        window.toolbarStyle = .unified
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let source = try #require(descendants(host).compactMap { $0 as? SessionInspectorTabDragView }.first)
        let center = NSPoint(x: source.bounds.midX, y: source.bounds.midY)
        let point = source.convert(center, to: host.superview)
        let hit = try #require(host.hitTest(point))
        #expect(hit is SessionInspectorTabDragView)
        #expect(!hit.mouseDownCanMoveWindow)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try mouse(type, at: source.convert(center, to: nil), in: window))
        }
        #expect(selections == 1)
    }

    @Test(arguments: [
        (false, false), (false, true),
    ])
    func closeTargetWorksAtItsEdgesWithoutSelectingTheTab(configuration: (Bool, Bool)) async throws {
        var closes = 0
        var selections = 0
        let tab = SessionInspectorTabItem(
            id: "preview", title: "A long background tab title", icon: .chatText, isSelected: configuration.1,
            select: { selections += 1 }, close: { closes += 1 })
        let host = NSHostingView(
            rootView: SessionInspectorTab(
                tab: tab, compact: configuration.0,
                drag: SessionInspectorTabDrag(workspace: "workspace", id: tab.id),
                reorder: { _ in false }, moveLeft: nil, moveRight: nil
            ).dockThemedRoot())
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!window.dockHasInteractiveChildWindow)
        for point in [
            NSPoint(x: host.bounds.maxX - 25, y: 4),
            NSPoint(x: host.bounds.maxX - 4, y: 16),
            NSPoint(x: host.bounds.maxX - 14, y: 29),
        ] {
            let before = closes
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: host.convert(point, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(30))
            #expect(closes == before + 1)
            #expect(selections == 0)
        }
    }

    @Test func compactLongTitlesStayBounded() {
        let tab = SessionInspectorTabItem(
            id: "preview", title: String(repeating: "Long title ", count: 20), icon: .chatText,
            isSelected: false, select: {}, close: {})
        let host = NSHostingView(
            rootView: SessionInspectorTab(
                tab: tab, compact: true, drag: SessionInspectorTabDrag(workspace: "workspace", id: tab.id),
                reorder: { _ in false }, moveLeft: nil, moveRight: nil
            ).dockThemedRoot())
        #expect(host.fittingSize.width <= 32)
        #expect(host.fittingSize.height == 32)
    }

    @Test func movesAcrossTabKindsInBothDirections() {
        let order = SessionInspectorTabOrder()
        let ids = ["section:Timeline", "extra:terminal", "preview:message", "section:Browser"]
        let workspace = "backend:profile:session"
        #expect(
            order.move(
                SessionInspectorTabDrag(workspace: workspace, id: ids[0]), to: ids[3], available: ids, in: workspace))
        #expect(order.ordered(ids, in: workspace) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(
            order.move(
                SessionInspectorTabDrag(workspace: workspace, id: ids[0]), to: ids[1], available: ids, in: workspace))
        #expect(order.ordered(ids, in: workspace) == ids)
    }

    @Test func closingAndOpeningTabsReconcilesTheVisibleOrder() {
        let order = SessionInspectorTabOrder()
        let ids = ["section:Timeline", "preview:first", "preview:second"]
        let drag = SessionInspectorTabDrag(workspace: "workspace", id: ids[2])
        order.move(drag, to: ids[0], available: ids, in: "workspace")
        let available = [ids[0], ids[2], "extra:new"]
        #expect(order.ordered(available, in: "workspace") == [ids[2], ids[0], "extra:new"])
        #expect(order.ordered([], in: "workspace").isEmpty)
        // A new move forgets removed IDs and keeps newly opened tabs.
        order.move(drag, to: "extra:new", available: available, in: "workspace")
        #expect(order.orders["workspace"] == [ids[0], "extra:new", ids[2]])
    }

    @Test func foreignStaleAndSelfDropsDoNotChangeOrder() {
        let order = SessionInspectorTabOrder()
        let ids = ["section:Timeline", "preview:message"]
        for workspace in ["backend-a:profile-a:session", "backend-a:profile-b:session", "backend-b:profile-a:session"] {
            #expect(
                !order.move(
                    SessionInspectorTabDrag(workspace: "other", id: ids[0]), to: ids[1], available: ids, in: workspace))
        }
        for (source, target) in [("missing", ids[0]), (ids[0], "missing"), (ids[0], ids[0])] {
            #expect(
                !order.move(
                    SessionInspectorTabDrag(workspace: "workspace", id: source), to: target,
                    available: ids, in: "workspace"))
        }
        #expect(order.orders.isEmpty)
        order.move(
            SessionInspectorTabDrag(workspace: "one", id: ids[0]), to: ids[1], available: ids, in: "one")
        #expect(order.ordered(ids, in: "one") == ids.reversed())
        #expect(order.ordered(ids, in: "two") == ids)
    }

    @Test func renderCompactAndLabeledTabs() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_INSPECTOR_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previous = DockThemeRuntime.current
        let appearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = previous
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = appearance
        }
        let title = "PR #5564 is mergeable and targets the correct release branch with all required checks passing"
        let selected = SessionInspectorTabItem(
            id: "message", title: title, icon: .chatText, isSelected: true, select: {}, close: {})
        let background = SessionInspectorTabItem(
            id: "timeline", title: "Timeline", icon: .chartBarHorizontal, isSelected: false, select: {}, close: {})
        for (theme, dark) in [
            (DockThemeID.clean, false), (.clean, true), (.glass, true), (.mono, false), (.mono, true),
        ] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [300.0, 760.0] {
                let view = VStack(alignment: .leading, spacing: 16) {
                    ForEach([false, true], id: \.self) { compact in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 2) {
                                ForEach([background, selected]) { tab in
                                    SessionInspectorTab(
                                        tab: tab, compact: compact,
                                        drag: SessionInspectorTabDrag(workspace: "workspace", id: tab.id),
                                        reorder: { _ in true }, moveLeft: nil, moveRight: nil)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(width: width, height: 140)
                .background(Color.dockCanvas)
                .dockThemedRoot()
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 140)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("tabs-\(theme.rawValue)-\(dark)-\(Int(width)).png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor
private final class RecordingTabDragView: SessionInspectorTabDragView {
    var starts = 0
    var item: NSDraggingItem?
    override func beginDrag(with event: NSEvent) {
        starts += 1
        item = draggingItem()
    }
}

@MainActor
private final class TabStripFixtureState: ObservableObject {
    @Published var selected = 0
    @Published var width: CGFloat = 720
    let titles = (0..<12).map { "Tab \($0)" }
}

private struct TabStripFixture: View {
    @ObservedObject var state: TabStripFixtureState
    var body: some View {
        SessionInspectorTabStrip(
            tabs: state.titles.enumerated().map { index, title in
                SessionInspectorTabItem(
                    id: String(index), title: title, icon: .chatText, isSelected: state.selected == index,
                    select: { state.selected = index }, close: {})
            }, workspace: "workspace", reorder: { _, _ in false }
        ).frame(width: state.width)
    }
}
