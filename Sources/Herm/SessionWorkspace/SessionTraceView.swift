import AppKit
import Combine
import SwiftUI

struct SessionTraceView: View, Equatable {
    /// Not observed: streaming changes reach the timeline only through the
    /// throttled projection below, never as a re-render per token.
    let model: DockModel
    var isVisible = true
    @StateObject private var trace = SessionTraceModel()
    private let themeRevision: Int
    init(
        model: DockModel, isVisible: Bool = true,
        trace: @autoclosure @escaping () -> SessionTraceModel = SessionTraceModel()
    ) {
        self.model = model
        self.isVisible = isVisible
        themeRevision = DockThemeRuntime.revision
        _trace = StateObject(wrappedValue: trace())
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.isVisible == rhs.isVisible && lhs.themeRevision == rhs.themeRevision
    }
    @Environment(\.expandedReviewRouter) private var router
    /// False while the inspector panel is collapsed (it stays mounted) or covered.
    @Environment(\.localPreviewDiscoveryVisible) private var panelVisible
    @State private var expandedSheet = false
    @State private var expandedLayer: UUID?
    /// Hidden timelines neither project nor tick; the expanded copy keeps the feed alive.
    private var active: Bool { isVisible && (panelVisible || trace.isExpanded) }

    var body: some View {
        SessionTraceCanvas(
            turns: trace.turns, connected: trace.connected,
            availableSessionIDs: trace.sessionIDs, isVisible: isVisible && panelVisible,
            isLoading: trace.isLoading, listMaxHeight: 360, expand: expand, openSession: open
        )
        .sheet(isPresented: $expandedSheet) {
            SessionTraceExpanded(trace: trace, open: open) { expandedSheet = false }
                .frame(minWidth: 900, minHeight: 640)
                .modifier(ReviewSheetContext())
        }
        .onAppear { if active { trace.observe(model) } }
        .onChange(of: active) { _, active in
            if active { trace.observe(model) } else { trace.suspend() }
        }
        // A tab or session change must not leave an expanded copy holding this trace.
        .onDisappear {
            trace.suspend()
            if let expandedLayer, router?.layers.last?.id == expandedLayer {
                router?.close(restoreFocus: false)
            }
            expandedLayer = nil
        }
    }

    private func open(_ id: String) {
        if let session = model.sessions.first(where: { $0.id == id }) {
            model.resumeSession(session)
        }
    }

    /// Full-workspace layer when there is room; a sheet otherwise.
    private func expand() {
        let router = router
        let shown =
            router?.present(
                SessionTraceExpanded(trace: trace, open: open) { router?.close() }) ?? false
        if shown { expandedLayer = router?.layers.last?.id } else { expandedSheet = true }
    }
}

/// The same projection, uncapped, over the whole workspace. The inspector's
/// timeline stays mounted and keeps feeding `trace`.
private struct SessionTraceExpanded: View {
    @ObservedObject var trace: SessionTraceModel
    let open: (String) -> Void
    let close: () -> Void

    var body: some View {
        DockExpandedPage(title: "Timeline", subtitle: "Session execution", close: close) {
            SessionTraceCanvas(
                turns: trace.turns, connected: trace.connected,
                availableSessionIDs: trace.sessionIDs, isLoading: trace.isLoading,
                openSession: { id in
                    close()
                    open(id)
                }
            )
            .padding(.horizontal, 16)
        }
        .onAppear { trace.isExpanded = true }
        .onDisappear { trace.isExpanded = false }
    }
}

/// Plays a finished trace back from its origin; `resumedAt == nil` means paused.
struct SessionTraceReplay: Equatable {
    var position: Double = 0
    var resumedAt: Date? = nil
    var speed: Double = 1

    func time(at now: Date, span: Double) -> Double {
        min(span, position + (resumedAt.map { max(0, now.timeIntervalSince($0)) * speed } ?? 0))
    }
    func playing(at now: Date, span: Double) -> Bool {
        resumedAt != nil && time(at: now, span: span) < span
    }
    mutating func pause(at now: Date, span: Double) {
        position = time(at: now, span: span)
        resumedAt = nil
    }
    mutating func play(at now: Date, span: Double) {
        if time(at: now, span: span) >= span { position = 0 }
        resumedAt = now
    }
    mutating func setSpeed(_ value: Double, at now: Date, span: Double) {
        if resumedAt != nil {
            position = time(at: now, span: span)
            resumedAt = now
        }
        speed = value
    }
    /// The part of a step already reached by the playhead; nil before it starts.
    static func visibleElapsed(offset: Double, elapsed: Double, at time: Double) -> Double? {
        time < offset ? nil : min(elapsed, time - offset)
    }
}

/// Value-only surface: fixture rendering exercises the same layout as live sessions.
struct SessionTraceCanvas: View {
    #if DEBUG
        @Environment(\.conversationRowEvaluation) private var evaluation
    #endif
    let turns: [SessionTraceTurn]
    let connected: Bool
    var availableSessionIDs = Set<String>()
    var isVisible = true
    var isLoading = false
    var initialSelectionID: String? = nil
    /// Inspector cap; the step detail docks below the list instead of floating.
    var listMaxHeight: CGFloat? = nil
    var expand: (() -> Void)? = nil
    var openSession: (String) -> Void = { _ in }
    @State private var selectedTurnID: String? = SessionTraceProjection.allTurnsID
    @State private var selectedRowID: String?
    @State private var selectionRevision = 0
    @State private var collapsed = Set<String>()
    @State private var showsSubagents = true
    @State private var showsSteps = true
    @State private var search = ""
    @State private var query = ""
    @State private var follow = true
    @State private var fitted = false
    @State private var fittedSpan: Double = 30
    /// Observed only by plot drawing, so scrolling never re-renders the labels.
    @State private var scroll = SessionTraceScroll()
    @State private var rowViewport = SessionTraceRowViewport()
    @State private var replay: SessionTraceReplay?
    @State private var speed: Double = 1
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rowHeight: CGFloat = 34
    private let speeds: [Double] = [0.5, 1, 1.5, 2, 4]
    private var showsAll: Bool { selectedTurnID == SessionTraceProjection.allTurnsID }
    /// Resolve once per render: All mode rebuilds the combined timeline.
    private var currentTurn: SessionTraceTurn? {
        showsAll
            ? SessionTraceProjection.combined(turns)
            : turns.first { $0.id == selectedTurnID } ?? turns.last
    }
    private var animates: Bool { !reduceMotion && DockThemeStyle.current.animates }

    var body: some View {
        let turn = currentTurn
        #if DEBUG
            let _ = evaluation?("timeline-canvas", 0)
        #endif
        return GeometryReader { geometry in
            let labelWidth = min(280, max(150, geometry.size.width * 0.42))
            let floats =
                listMaxHeight == nil && geometry.size.width >= 620 && geometry.size.height >= 520
            VStack(spacing: 0) {
                header(turn)
                if let turn {
                    trace(turn, size: geometry.size, labelWidth: labelWidth, floats: floats)
                } else if isLoading {
                    DockLoadingState(title: "Loading timeline…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connected ? "No activity yet" : "Timeline unavailable")
                            .dockFont(size: 12, weight: .semibold)
                        Text(
                            connected
                                ? "Send a message to see agent and tool activity here."
                                : "Connect to Hermes to load session activity."
                        )
                        .dockFont(size: 12).foregroundStyle(Color.dockSecondaryText)
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(Color.dockCanvas)
        }
        .onAppear {
            if let initialSelectionID { select(initialSelectionID) }
            if let turn, !turn.rows.contains(where: \.active) {
                fittedSpan = extent(turn)
                fitted = true
            }
        }
        .onChange(of: follow) { _, value in
            if !value, selectedTurnID == nil { selectedTurnID = turn?.id }
        }
        .task(id: search) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            query = search
        }
        // Park a finished replay so the clock stops ticking.
        .task(id: replay) {
            guard let replay, replay.resumedAt != nil, let turn else { return }
            let span = extent(turn)
            let remaining = (span - replay.time(at: Date(), span: span)) / replay.speed
            do { try await Task.sleep(for: .seconds(max(0, remaining))) } catch { return }
            self.replay?.pause(at: Date(), span: span)
        }
        .onChange(of: turn?.id) { _, _ in
            selectedRowID = nil
            collapsed = []
            scroll.x = 0
            fitted = false
            replay = nil
        }
    }

    // MARK: Header

    private func header(_ turn: SessionTraceTurn?) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("All activity") { selectedTurnID = SessionTraceProjection.allTurnsID }
                Divider()
                ForEach(turns.reversed()) { item in
                    Button(item.title.isEmpty ? "Session request" : item.title) {
                        selectedTurnID = item.id
                        follow = false
                    }
                }
                Divider()
                Button("Follow current turn") {
                    selectedTurnID = nil
                    follow = true
                }
            } label: {
                HStack(spacing: 5) {
                    Text(turn?.title.isEmpty == false ? turn!.title : "Session request")
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                .dockFont(.body, weight: .semibold)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(turns.isEmpty)
            .help("Choose a request")
            Spacer(minLength: 4)
            if let expand {
                DockIconButton(
                    icon: .arrowsOutSimple, label: "Expand timeline", size: 24,
                    style: DockThemePalette(theme: DockThemeRuntime.current), action: expand)
            }
        }
        .padding(.vertical, 10)
    }

    /// Search, Fit and Live act only on the steps, so they sit on the Steps header.
    private var stepControls: some View {
        HStack(spacing: 6) {
            searchField
            Button("Fit") { fit() }
                .buttonStyle(.dockCompact).disabled(turns.isEmpty)
                .help("Fit the whole request in view")
            Button {
                follow.toggle()
                fitted = false
                if follow, !showsAll { selectedTurnID = nil }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(follow ? Color.dockSuccess : Color.dockSecondaryText)
                        .frame(width: 6, height: 6)
                    Text("Live")
                }
            }
            .buttonStyle(.dockCompact)
            .help("Follow new activity as it arrives. Scrolling the timeline turns this off.")
            .accessibilityLabel("Live tracking")
            .accessibilityValue(follow ? "On" : "Off")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.dockSecondaryText)
            TextField("Search", text: $search).textFieldStyle(.plain).dockFont(.body)
                .focused($searchFocused)
                .onExitCommand {
                    search = ""
                    searchFocused = false
                }
            if search.isEmpty {
                Text("⌘F").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).stroke(
                            Color.dockBorderLight, lineWidth: 0.5))
            } else {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.dockHover).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(minWidth: 110, maxWidth: 220).frame(height: 26)
        .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 6))
        .background {
            Button("Search steps") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    // MARK: Trace

    /// Everything on the time axis that moves with the clock.
    private struct Frame {
        let origin: Date
        let span: Double
        let replayTime: Double?
        let scale: CGFloat
        let width: CGFloat
        let playhead: CGFloat?
    }

    private func frame(_ bounds: SessionTraceTimeBounds, now: Date, plotWidth: CGFloat) -> Frame {
        let span = bounds.span(at: now)
        let replayTime = replay?.time(at: now, span: span)
        let scale =
            fitted
            ? max(20, plotWidth - 96) / max(1, fittedSpan)
            : min(12, 100_000 / span)
        let playhead: CGFloat? =
            replayTime.map { $0 * scale }
            ?? (bounds.hasTimedActivity ? span * scale : nil)
        return Frame(
            origin: bounds.origin, span: span, replayTime: replayTime, scale: scale,
            width: max(plotWidth, span * scale + 96), playhead: playhead)
    }

    /// Ticks only while something moves; labels and details stay outside it.
    private func clock<Content: View>(_ live: Bool, @ViewBuilder _ content: @escaping (Date) -> Content)
        -> some View
    {
        TimelineView(
            .animation(
                minimumInterval: animates ? 0.1 : 1,
                paused: !isVisible || (!live && replay?.resumedAt == nil)
            )
        ) { content($0.date) }
    }

    private func trace(_ turn: SessionTraceTurn, size: CGSize, labelWidth: CGFloat, floats: Bool)
        -> some View
    {
        let visible = SessionTraceProjection.visible(turn.rows, collapsed: collapsed, query: query)
        let bounds = SessionTraceTimeBounds(turn)
        let live = connected && turn.rows.contains(where: \.active)
        let plotWidth = max(100, size.width - 16 - labelWidth)
        let selected = turn.rows.first { $0.id == selectedRowID }
        return VStack(spacing: DockSpacing.group) {
            metrics(turn, bounds: bounds, live: live)
            agentList(turn, live: live)
                .fixedSize(horizontal: false, vertical: true)
                .dockCard(padding: 8)
            VStack(spacing: 0) {
                sectionHeader("Steps", count: turn.rows.count, isExpanded: $showsSteps) {
                    if showsSteps { stepControls }
                }
                if showsSteps {
                    HStack(spacing: 0) {
                        Text("Step").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                            .padding(.leading, 4)
                            .frame(width: labelWidth, alignment: .leading)
                        Color.dockBorderLight.frame(width: 0.5)
                        clock(live) { now in
                            let frame = frame(bounds, now: now, plotWidth: plotWidth)
                            SessionTraceScrolled(scroll: scroll) { offset in
                                ruler(width: plotWidth, scale: frame.scale, playhead: frame.playhead, offset: offset)
                            }
                        }
                        .frame(width: plotWidth - 0.5, alignment: .leading).clipped()
                        Spacer(minLength: 0)
                    }
                    .frame(height: 26)
                    .background(Color.dockSurface2.opacity(0.5))
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                    waterfall(
                        visible, turn: turn, bounds: bounds, live: live, labelWidth: labelWidth,
                        plotWidth: plotWidth, selectionFloats: floats
                    )
                    .frame(maxHeight: listMaxHeight ?? .infinity)
                    .id(turn.id)
                    footer(turn)
                }
                if !floats, let selected {
                    detail(selected, turn: turn, live: live)
                        .frame(
                            minHeight: listMaxHeight == nil ? 280 : 200,
                            maxHeight: listMaxHeight == nil ? 280 : .infinity
                        )
                        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
                }
            }
            .dockCard(padding: 8)
            if listMaxHeight != nil {
                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if floats, let selected {
                let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
                detail(selected, turn: turn, live: live)
                    .frame(width: 380, height: 340)
                    .clipShape(shape)
                    .dockFloatingSurface(shape, tint: Color.dockSurface2)
                    .padding(12)
                    .padding(.bottom, 38)  // clears the replay footer
            }
        }
    }

    private func metrics(_ turn: SessionTraceTurn, bounds: SessionTraceTimeBounds, live: Bool) -> some View {
        HStack(spacing: 0) {
            clock(live) { now in
                metric(
                    "Duration", value: bounds.hasTiming ? time(bounds.span(at: now)) : "—",
                    help: showsAll
                        ? "Active time across requests; idle time between them is collapsed"
                        : "Wall time from the request to its last traced step")
            }
            divider
            metric(
                "Model calls", value: "\(turn.modelCallCount)",
                help:
                    "Derived from Hermes step timestamps plus calls delegates report. The final reply is not counted."
            )
            divider
            metric("Tool calls", value: "\(turn.toolCount)")
            if turn.agentCount > 0 {
                divider
                metric("Delegates", value: "\(turn.agentCount)")
            }
            if let tokens = turn.reportedTokens {
                divider
                metric(
                    "Tokens", value: compact(tokens), help: "Tokens reported by delegates")
            }
            divider
            metric(
                "Errors", value: "\(turn.errorCount)",
                tint: turn.errorCount > 0 ? .dockDestructive : nil)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var divider: some View { Color.dockBorderLight.frame(width: 0.5) }

    private func metric(_ title: String, value: String, help: String? = nil, tint: Color? = nil)
        -> some View
    {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
            Text(value).dockFont(size: 17, weight: .medium).monospacedDigit()
                .foregroundStyle(tint ?? Color.dockPrimaryText).lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    private func ruler(width: CGFloat, scale: CGFloat, playhead: CGFloat?, offset: CGFloat) -> some View {
        Canvas { context, size in
            let step = tickStep(scale)
            for tick in stride(
                from: floor(offset / scale / step) * step, through: Double((offset + width) / scale), by: step)
            {
                context.draw(
                    Text(tickLabel(tick)).font(DockTypography.metadata)
                        .foregroundColor(Color.dockSecondaryText),
                    at: CGPoint(x: tick * scale - offset + 6, y: size.height / 2), anchor: .leading)
            }
            if let playhead {
                context.fill(
                    Path(ellipseIn: CGRect(x: playhead - offset - 3.5, y: size.height - 7, width: 7, height: 7)),
                    with: .color(Color.dockPrimaryText))
            }
        }.frame(width: width, height: 30)
    }

    private func waterfall(
        _ items: [(row: SessionTraceRow, depth: Int)], turn: SessionTraceTurn, bounds: SessionTraceTimeBounds,
        live: Bool,
        labelWidth: CGFloat, plotWidth: CGFloat, selectionFloats: Bool
    ) -> some View {
        let slowest = turn.slowestRowID
        let childIDs = Set(turn.rows.compactMap(\.parentID))
        let last = items.last?.row.id
        return ScrollViewReader { vertical in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    SessionTraceRowWindow(viewport: rowViewport, items: items) { row, depth in
                        stepLabel(
                            row, depth: depth,
                            hasChildren: childIDs.contains(row.id)
                        ).id("trace-label:" + row.id)
                    }.frame(width: labelWidth)
                    Color.dockBorderLight.frame(width: 0.5)
                    clock(live) { now in
                        let frame = frame(bounds, now: now, plotWidth: plotWidth)
                        bars(items, frame: frame, now: now, slowest: slowest, plotWidth: plotWidth)
                    }
                }
                .frame(height: CGFloat(items.count) * rowHeight)
                .background { SessionTraceViewportObserver(viewport: rowViewport) }
                .background {
                    SessionTraceScrollObserver(scroll: nil) { if isVisible { follow = false } }
                }
                Color.clear.frame(height: selectionFloats && selectedRowID != nil ? 270 : 0)
                    .id("trace-vertical-tail")
                if items.isEmpty {
                    Text("No matching steps").dockFont(size: 12)
                        .foregroundStyle(Color.dockSecondaryText).padding(20)
                }
            }
            .frame(maxHeight: .infinity)
            // Live keeps the end of the waterfall in view as rows arrive.
            .onChange(of: last) { _, id in
                guard follow, id != nil else { return }
                withAnimation(animates ? .dockEase(duration: 0.25) : nil) {
                    vertical.scrollTo("trace-vertical-tail", anchor: .bottom)
                }
            }
            .onChange(of: follow) { _, value in
                guard value, last != nil else { return }
                vertical.scrollTo("trace-vertical-tail", anchor: .bottom)
            }
            .onAppear {
                if follow, last != nil { vertical.scrollTo("trace-vertical-tail", anchor: .bottom) }
            }
            .onChange(of: selectedRowID) { old, id in
                guard old == nil || selectionFloats, let id else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard selectedRowID == id else { return }
                    guard let index = items.firstIndex(where: { $0.row.id == id }) else { return }
                    rowViewport.scroll(to: index, centered: selectionFloats)
                }
            }
        }
    }

    private func bars(
        _ items: [(row: SessionTraceRow, depth: Int)], frame: Frame, now: Date, slowest: String?, plotWidth: CGFloat
    ) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    SessionTraceScrolled(scroll: scroll) { offset in
                        SessionTraceRowWindow(viewport: rowViewport, items: items) { row, _ in
                            barRow(
                                row, origin: frame.origin, now: now,
                                replayTime: frame.replayTime, width: frame.width,
                                scale: frame.scale, slowest: row.id == slowest,
                                viewport: CGRect(x: offset, y: 0, width: plotWidth, height: rowHeight))
                        }
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Color.clear.frame(width: 1, height: 1).id("trace-tail")
                    }
                }
                .frame(width: frame.width)
                .background(alignment: .topLeading) {
                    SessionTracePlotViewport(
                        scroll: scroll, viewport: rowViewport,
                        width: plotWidth, height: CGFloat(items.count) * rowHeight
                    ) { offset, height in
                        grid(
                            width: plotWidth, height: height, scale: frame.scale,
                            playhead: frame.playhead, offset: offset)
                    }
                }
                .background {
                    SessionTraceScrollObserver(scroll: scroll) { if isVisible { follow = false } }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 3).onChanged { _ in follow = false }
            )
            .onChange(of: frame.span.rounded(.down)) { _, _ in
                if follow {
                    withAnimation(animates ? .dockEase(duration: 0.35) : nil) {
                        reader.scrollTo("trace-tail", anchor: .trailing)
                    }
                }
            }
            .onAppear { if follow { reader.scrollTo("trace-tail", anchor: .trailing) } }
            .onChange(of: follow) { _, value in
                if value { reader.scrollTo("trace-tail", anchor: .trailing) }
            }
            .task(id: selectionRevision) {
                await Task.yield()
                guard !Task.isCancelled,
                    let row = items.first(where: { $0.row.id == selectedRowID })?.row,
                    let start = row.start, let elapsed = row.elapsed(at: now)
                else { return }
                scroll.reveal(
                    SessionTraceBarLayout(
                        offset: start.timeIntervalSince(frame.origin), elapsed: elapsed,
                        scale: frame.scale, contentWidth: frame.width))
            }
        }
    }

    /// Below the steps: one card per delegate (who, its task, what it is doing), or why there are none.
    private func agentList(_ turn: SessionTraceTurn, live: Bool) -> some View {
        let agents = turn.rows.filter { $0.kind == .agent }
        let cards = VStack(spacing: 0) {
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                agentCard(
                    agent, number: index + 1, live: live,
                    steps: turn.rows.filter { $0.parentID == agent.id }.count)
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Subagents", count: agents.count, isExpanded: $showsSubagents)
            if !showsSubagents {
                EmptyView()
            } else if agents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No subagents").dockFont(size: 12, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Agents this request delegates to appear here with their task.")
                        .dockFont(size: 12).foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 12)
            } else {
                ViewThatFits(in: .vertical) {
                    cards
                    ScrollView(.vertical) { cards }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    /// Steps and Subagents share one collapsible header so the sections read alike.
    private func sectionHeader<Actions: View>(
        _ title: String, count: Int, isExpanded: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) -> some View {
        DockSectionHeader(
            title: title, count: count, isExpanded: isExpanded,
            style: DockThemePalette(theme: DockThemeRuntime.current), isContentHeader: true,
            titleRole: .conversation,
            actions: actions
        )
        .padding(.leading, 4)
        .padding(.top, 4)
    }

    private func agentCard(_ agent: SessionTraceRow, number: Int, live: Bool, steps: Int)
        -> some View
    {
        let task = agent.input.map(SessionTraceProjection.taskTitle) ?? agent.title
        let name = agent.title == task ? "Agent \(number)" : agent.title
        let reported = agent.result.flatMap {
            $0.split(whereSeparator: \.isNewline).first.map(String.init)
        }
        return HStack(alignment: .top, spacing: 0) {
            Button {
                select(agent.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    stepIcon(agent)
                        .frame(width: 24, height: 24)
                        .background(tile(agent), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(name).dockFont(.metadata, weight: .semibold)
                            if let model = agent.model { Text(model) }
                            Text(steps == 1 ? "1 step" : "\(steps) steps")
                            Spacer(minLength: 4)
                            clock(live && agent.active) { now in
                                Text(agent.elapsed(at: now).map(time) ?? "—").monospacedDigit()
                            }
                            statusPill(agent)
                        }
                        .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                        Text(task).dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText).lineLimit(2)
                        if let activity = agent.activity {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).accessibilityLabel("Running")
                                Text(activity).lineLimit(1)
                            }
                            .dockFont(.metadata).foregroundStyle(Color.dockPrimaryText)
                        } else if let reported {
                            Text((try? AttributedString(markdown: reported)) ?? AttributedString(reported))
                                .dockFont(.metadata)
                                .foregroundStyle(Color.dockSecondaryText).lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            if let related = agent.relatedSessionID, availableSessionIDs.contains(related) {
                Button {
                    openSession(related)
                } label: {
                    DockIcon(.arrowSquareOut, size: 11, color: Color.dockSecondaryText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.dockHover)
                .padding(.top, 9).padding(.trailing, 6)
                .help("Open \(name)'s conversation")
                .accessibilityLabel("Open \(name)'s conversation")
            }
        }
        .background(selectedRowID == agent.id ? Color.dockSurface2 : Color.clear)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func stepLabel(_ row: SessionTraceRow, depth: Int, hasChildren: Bool) -> some View {
        #if DEBUG
            let _ = evaluation?("timeline-label", 0)
        #endif
        return HStack(spacing: 4) {
            if hasChildren {
                Button {
                    withAnimation(animates ? .dockEase(duration: 0.2) : nil) {
                        if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                        .rotationEffect(
                            .degrees(collapsed.contains(row.id) && query.isEmpty ? 0 : 90)
                        )
                        .frame(width: 16, height: 28)
                }
                .buttonStyle(.dockHover).disabled(!query.isEmpty)
                .accessibilityLabel(
                    "\(collapsed.contains(row.id) ? "Expand" : "Collapse") \(row.title)")
            } else {
                Color.clear.frame(width: 16)
            }
            Button {
                select(row.id)
            } label: {
                HStack(spacing: 7) {
                    stepIcon(row)
                        .frame(width: 20, height: 20)
                        .background(tile(row), in: RoundedRectangle(cornerRadius: 5))
                    if row.active {
                        ProgressView().controlSize(.mini).accessibilityLabel("Running")
                    }
                    Text(row.title)
                        .dockFont(.body, weight: hasChildren ? .semibold : .regular)
                        .foregroundStyle(
                            row.kind == .model ? Color.dockSecondaryText : Color.dockPrimaryText
                        )
                        .lineLimit(1).layoutPriority(1)
                    if let model = row.model {
                        Text(model).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: rowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            if row.kind == .agent, let related = row.relatedSessionID,
                availableSessionIDs.contains(related)
            {
                Button {
                    openSession(related)
                } label: {
                    DockIcon(.arrowSquareOut, size: 11, color: Color.dockSecondaryText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.dockHover)
                .help("Open \(row.title)'s conversation")
                .accessibilityLabel("Open \(row.title)'s conversation")
            }
        }
        .padding(.leading, CGFloat(min(depth, 5)) * 14)
        .padding(.trailing, 8)
        .background {
            Canvas { context, size in
                guard depth > 0 else { return }
                var path = Path()
                for level in 0..<min(depth, 5) {
                    let x = CGFloat(level) * 14 + 8
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: .color(Color.dockBorderLight), lineWidth: 0.5)
            }.allowsHitTesting(false)
        }
        .frame(height: rowHeight)
        .background(selectedRowID == row.id ? Color.dockSurface2 : Color.clear)
        .help(row.title)
    }

    private func barRow(
        _ row: SessionTraceRow, origin: Date, now: Date, replayTime: Double?, width: CGFloat,
        scale: CGFloat, slowest: Bool, viewport: CGRect
    ) -> some View {
        #if DEBUG
            let _ = evaluation?("timeline-bar", 0)
        #endif
        let full = row.elapsed(at: now)
        let offset = row.start?.timeIntervalSince(origin) ?? 0
        let elapsed =
            replayTime.map { time in
                full.flatMap {
                    SessionTraceReplay.visibleElapsed(offset: offset, elapsed: $0, at: time)
                }
            } ?? full
        return ZStack(alignment: .leading) {
            if row.start != nil, let elapsed {
                let layout = SessionTraceBarLayout(
                    offset: offset, elapsed: elapsed, scale: scale, contentWidth: width)
                if let side = layout.offscreen(in: viewport) {
                    HStack {
                        if side == .later { Spacer(minLength: 0) }
                        Button {
                            select(row.id)
                        } label: {
                            Label(
                                barLabel(row, elapsed: elapsed),
                                systemImage: side == .earlier ? "arrow.left" : "arrow.right"
                            )
                            .dockFont(.metadata).monospacedDigit()
                        }
                        .buttonStyle(.dockCompact)
                        .help(
                            side == .earlier
                                ? "Show this step earlier in the timeline" : "Show this step later in the timeline")
                        if side == .earlier { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, 6)
                } else {
                    Button {
                        select(row.id)
                    } label: {
                        bar(row, width: layout.width)
                    }
                    .buttonStyle(.dockHover)
                    .offset(x: layout.x - viewport.minX)
                    HStack(spacing: 6) {
                        Text(barLabel(row, elapsed: elapsed)).dockFont(.metadata).monospacedDigit()
                            .foregroundStyle(Color.dockSecondaryText)
                        if slowest, replayTime.map({ $0 >= offset + (full ?? 0) }) ?? true {
                            Text("Slowest").dockFont(.metadata, weight: .medium)
                                .foregroundStyle(DockAccentColor.amber.color)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(DockAccentColor.amber.fill.opacity(0.14)))
                                .overlay(Capsule().stroke(DockAccentColor.amber.fill.opacity(0.4)))
                        }
                    }
                    .fixedSize()
                    .offset(x: layout.x - viewport.minX + layout.width + 6).allowsHitTesting(false)
                }
            } else if row.start == nil || full == nil {
                // Missing intervals stay explicit; future replay steps remain hidden.
                Text(row.active ? "Running · timing unavailable" : "No timing")
                    .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    .padding(.leading, 8)
            }
        }
        .frame(width: viewport.width, height: rowHeight, alignment: .leading)
        .clipped()
        .offset(x: viewport.minX)
        .frame(width: width, height: rowHeight, alignment: .leading)
        .background(selectedRowID == row.id ? Color.dockSurface2 : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.title), \(row.status), \(full.map(time) ?? "timing unavailable"), \(row.timing.rawValue) timing"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(row.id) }
    }

    private func bar(_ row: SessionTraceRow, width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        let fill: Color =
            row.failed
            ? DockAccentColor.coral.fill
            : row.kind == .turn ? Color.dockSecondaryText : tone(row).fill
        let opacity: Double =
            switch row.kind {
            case .turn: 0.22
            case .thinking, .marker: 0.55
            case .agent: 0.5
            case .model: 0.75
            default: 0.9
            }
        return shape.fill(fill.opacity(opacity))
            .overlay {
                if row.kind == .turn || row.kind == .agent {
                    SessionTraceHatching()
                        .stroke(fill.opacity(0.5), lineWidth: 0.6)
                        .clipShape(shape)
                }
            }
            .overlay(alignment: .trailing) {
                if row.active {
                    Capsule().fill(tone(row).color).frame(width: 2).padding(.vertical, 2)
                }
            }
            .overlay {
                shape.stroke(
                    selectedRowID == row.id ? Color.dockPrimaryText : Color.clear, lineWidth: 1.5)
            }
            .overlay {
                if row.failed, width > 18 {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.dockOnAccentText)
                }
            }
            .frame(width: width, height: row.kind == .turn ? 16 : 18)
            .animation(animates && row.active ? .linear(duration: 0.1) : nil, value: width)
            .contentShape(Rectangle())
    }

    private func grid(width: CGFloat, height: CGFloat, scale: CGFloat, playhead: CGFloat?, offset: CGFloat)
        -> some View
    {
        Canvas { context, _ in
            let step = tickStep(scale)
            for tick in stride(
                from: floor(offset / scale / step) * step, through: Double((offset + width) / scale), by: step)
            {
                var path = Path()
                path.move(to: CGPoint(x: tick * scale - offset, y: 0))
                path.addLine(to: CGPoint(x: tick * scale - offset, y: height))
                context.stroke(path, with: .color(Color.dockBorderLight), lineWidth: 0.5)
            }
            if let playhead {
                var path = Path()
                path.move(to: CGPoint(x: playhead - offset, y: 0))
                path.addLine(to: CGPoint(x: playhead - offset, y: height))
                context.stroke(
                    path, with: .color(Color.dockPrimaryText.opacity(0.65)), lineWidth: 1)
            }
        }.frame(width: width, height: height).allowsHitTesting(false)
    }

    // MARK: Detail

    private func detail(_ row: SessionTraceRow, turn: SessionTraceTurn, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stepIcon(row)
                    .frame(width: 24, height: 24)
                    .background(tile(row), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).dockFont(.body, weight: .semibold).lineLimit(1)
                    if let subtitle = detailSubtitle(row, turn: turn) {
                        Text(subtitle).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1).truncationMode(.middle).help(subtitle)
                    }
                }
                .layoutPriority(1)
                statusPill(row)
                Spacer(minLength: 4)
                Button {
                    select(nil)
                } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(.dockHover).accessibilityLabel("Close step details")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Only the metrics tick; the Markdown below renders once.
                    clock(live && row.active) { now in
                        detailGrid(
                            row, origin: turn.rows.compactMap(\.start).min() ?? turn.start,
                            now: now)
                    }
                    detailSection("Now", icon: .pulse, row.activity, .input, row)
                    detailSection(row.kind == .agent ? "Goal" : "Input", icon: .arrowLineDown, row.input, .input, row)
                    detailSection(
                        row.kind == .agent ? "Summary" : "Result", icon: row.failed ? .xCircle : .arrowLineUp,
                        row.result, .result, row)
                    detailSection("Diff", icon: .gitDiff, row.diff, .diff, row)
                    if let related = row.relatedSessionID {
                        if availableSessionIDs.contains(related) {
                            Button("Open conversation") { openSession(related) }
                                .buttonStyle(.dockLink)
                        } else {
                            Text("Session · " + related).dockFont(.metadata)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.dockSurface2)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func statusPill(_ row: SessionTraceRow) -> some View {
        let color = statusColor(row)
        let label =
            row.active
            ? "Running"
            : row.failed ? "Failed" : row.outcome == "Succeeded" ? "Done" : "Finished"
        return Text(label).dockFont(.metadata, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
            .lineLimit(1).fixedSize()
            .help(row.status).accessibilityLabel(row.status)
    }

    private func detailGrid(_ row: SessionTraceRow, origin: Date, now: Date) -> some View {
        var cells: [(String, String)] = []
        if row.kind != .marker, let duration = row.elapsed(at: now) {
            cells.append(("Duration", time(duration)))
        }
        if let start = row.start {
            cells.append(("Started", "+" + time(max(0, start.timeIntervalSince(origin)))))
        }
        if let value = row.inputTokens { cells.append(("Tokens in", compact(value))) }
        if let value = row.outputTokens { cells.append(("Tokens out", compact(value))) }
        if let value = row.apiCalls { cells.append(("Model calls", "\(value)")) }
        cells.append(
            (
                "Timing",
                row.kind == .model
                    ? "Derived"
                    : row.timing == .runtime
                        ? "Runtime" : row.timing == .observed ? "Observed" : "Unavailable"
            ))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
            alignment: .leading, spacing: 10
        ) {
            ForEach(cells, id: \.0) { cell in
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.0).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    Text(cell.1).dockFont(size: 14, weight: .medium).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .background(Color.dockSurface4, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Owner agent and the tool's file or command context, when they add something.
    private func detailSubtitle(_ row: SessionTraceRow, turn: SessionTraceTurn) -> String? {
        let owner = turn.rows.first { $0.id == row.parentID && $0.kind == .agent }
        let parts = [
            owner.map { $0.title + ($0.model.map { " · " + $0 } ?? "") } ?? (row.kind == .agent ? row.model : nil),
            row.context.flatMap { $0.isEmpty || $0 == row.title ? nil : $0 },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func detailSection(
        _ title: String, icon: Ph, _ value: String?,
        _ section: SessionTraceProjection.DetailSection, _ row: SessionTraceRow
    ) -> some View {
        if let markdown = SessionTraceProjection.detailMarkdown(value, section: section, kind: row.kind) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(title).dockFont(.metadata, weight: .semibold)
                } icon: {
                    DockIcon(
                        icon, size: 11,
                        color: section == .result && row.failed
                            ? DockAccentColor.coral.color : Color.dockSecondaryText)
                }
                .foregroundStyle(Color.dockSecondaryText)
                MarkdownMessageView(markdown: markdown, bodySize: DockTypography.size(.body))
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Footer

    private func footer(_ turn: SessionTraceTurn) -> some View {
        let finished = !turn.rows.contains(where: \.active) && turn.rows.contains { $0.start != nil }
        let span = extent(turn)
        return HStack(spacing: 6) {
            Button {
                let now = Date()
                var next = replay ?? SessionTraceReplay(speed: speed)
                if next.playing(at: now, span: span) {
                    next.pause(at: now, span: span)
                } else {
                    if replay == nil { fit() }
                    next.play(at: now, span: span)
                }
                replay = next
            } label: {
                Image(systemName: replay?.resumedAt != nil ? "pause.fill" : "play.fill")
                    .font(.system(size: 10)).frame(width: 24, height: 24)
                    .background(Color.dockSurface2, in: Circle())
                    .overlay(Circle().stroke(Color.dockBorderLight, lineWidth: 0.5))
            }
            .buttonStyle(.dockHover)
            .disabled(!finished)
            .help(finished ? "Replay this request" : "Replay is available once the request finishes")
            .accessibilityLabel(replay?.resumedAt != nil ? "Pause replay" : "Play replay")
            Button {
                if replay == nil { fit() }
                replay = SessionTraceReplay(resumedAt: Date(), speed: speed)
            } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 22, height: 22)
            }
            .buttonStyle(.dockHover).disabled(!finished)
            .help("Replay from the start").accessibilityLabel("Replay from the start")
            Menu {
                ForEach(speeds, id: \.self) { value in
                    Button {
                        speed = value
                        replay?.setSpeed(value, at: Date(), span: span)
                    } label: {
                        if value == speed {
                            Label(speedLabel(value), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(value))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(speedLabel(speed)).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .dockFont(.metadata)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(!finished).help("Replay speed")
            if replay != nil {
                Button("Exit replay") { replay = nil }.buttonStyle(.dockCompact)
            }
            Spacer(minLength: 8)
            coverage(turn)
            legend("Model", fills: [DockAccentColor.violet.fill.opacity(0.75)])
            legend(
                "Tool by type",
                fills: [DockAccentColor.teal, .orange, .blue].map { $0.fill.opacity(0.9) })
        }
        .frame(height: 38)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func legend(_ title: String, fills: [Color]) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(fills.indices, id: \.self) { fills[$0].frame(width: 12 / CGFloat(fills.count)) }
            }
            .frame(width: 12, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(title).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }
        .fixedSize()
    }

    @ViewBuilder private func coverage(_ turn: SessionTraceTurn) -> some View {
        if !connected {
            Label("Not current", systemImage: "wifi.slash")
                .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).fixedSize()
                .help("Not connected to Hermes · this timeline is not current")
        } else if turn.rows.contains(where: { $0.kind != .turn && $0.timing == .unavailable }) {
            Image(systemName: "clock.badge.questionmark")
                .foregroundStyle(Color.dockSecondaryText)
                .help("Partial trace · some steps have no timing")
                .accessibilityLabel("Partial trace, some steps have no timing")
        }
    }

    // MARK: Helpers

    private func fit() {
        if let turn = currentTurn { fittedSpan = extent(turn) }
        fitted = true
        follow = false
        scroll.reset()
    }

    private func select(_ id: String?) {
        if id != nil { follow = false }
        withAnimation(animates ? .dockEase(duration: 0.2) : nil) { selectedRowID = id }
        selectionRevision &+= 1
    }
    private func extent(_ turn: SessionTraceTurn) -> Double {
        let start = turn.rows.compactMap(\.start).min() ?? turn.start
        let end = turn.rows.compactMap { $0.finish(at: Date()) }.max() ?? start
        return max(1, end.timeIntervalSince(start))
    }

    private func statusColor(_ row: SessionTraceRow) -> Color {
        if row.failed { return .dockDestructive }
        if row.outcome == "Succeeded" { return .dockSuccess }
        if row.active { return .dockInfo }
        return .dockSecondaryText
    }

    private func barLabel(_ row: SessionTraceRow, elapsed: Double) -> String {
        if row.kind == .marker { return "Event" }
        // Restored steps carry only Hermes' finish stamp; never print a made-up 0s.
        if !row.active, row.duration == nil, row.start != nil, row.start == row.end { return "Finished" }
        let tokens = [row.inputTokens, row.outputTokens].compactMap { $0 }
        return tokens.isEmpty
            ? time(elapsed) : time(elapsed) + " · " + compact(tokens.reduce(0, +)) + " tok"
    }

    /// Roughly six to ten labelled ticks across whatever span is visible.
    private func tickStep(_ scale: CGFloat) -> Double {
        let target = 80 / Double(max(scale, 0.0001))
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return steps.first { $0 >= target } ?? ceil(target / 3600) * 3600
    }
    private func tickLabel(_ seconds: Double) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0
            ? "\(Int(seconds / 60))m" : String(format: "%.0fs", seconds)
    }
    private func time(_ seconds: Double) -> String {
        if seconds >= 60 {
            return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
        }
        return seconds < 10 ? String(format: "%.1fs", seconds) : String(format: "%.0fs", seconds)
    }
    private func compact(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000) : "\(value)"
    }
    private func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }
    /// Same glyphs as the chat's activity list, file tools included.
    @ViewBuilder private func stepIcon(_ row: SessionTraceRow) -> some View {
        if !row.failed, let name = row.toolName, TurnActivityView.isFileTool(name),
            let path = row.context,
            let image = ArtifactFileIcon.inlineImage(forPath: path, size: 14)
        {
            Image(nsImage: image).frame(width: 16, height: 16)
        } else {
            DockIcon(
                icon(row), size: 13,
                color: row.failed
                    ? Color.dockDestructive
                    : row.kind == .turn ? Color.dockSecondaryText : tone(row).color)
        }
    }
    private func tile(_ row: SessionTraceRow) -> Color {
        row.kind == .turn ? Color.dockSurface2 : tone(row).fill.opacity(0.16)
    }
    private func icon(_ row: SessionTraceRow) -> Ph {
        if row.failed { return .xCircle }
        switch row.kind {
        case .turn: return .chatText
        case .agent: return .usersThree
        case .model: return .sparkle
        case .tool: return row.toolName.map(TurnActivityView.icon(for:)) ?? .wrench
        case .thinking: return .brain
        case .compaction: return .arrowsInSimple
        case .marker: return .dotOutline
        }
    }
    /// Tools take their type's hue; delegates and model calls take their owner's.
    private func tone(_ row: SessionTraceRow) -> DockAccentColor {
        if row.failed { return .coral }
        switch row.kind {
        case .tool: return row.toolName.map(Self.toolTone) ?? .violet
        case .thinking: return .pink
        case .compaction: return .amber
        default: break
        }
        let owner = row.kind == .agent ? row.id : row.parentID ?? row.id
        guard owner.hasPrefix("agent:") else { return .violet }
        return DockAccentColor.identity(for: String(owner.dropFirst(6)))
    }
    /// Follows the chat's icon families so a glyph and its bar always agree.
    static func toolTone(_ name: String) -> DockAccentColor {
        switch TurnActivityView.icon(for: name) {
        case .terminal: .teal
        case .pencilSimple: .orange
        case .fileText: .blue
        case .magnifyingGlass: .cyan
        case .image: .tangerine
        case .listChecks: .amber
        case .usersThree: .pink
        case .globe: .indigo
        case .brain: .green
        default:
            // Coral stays reserved for failures.
            DockAccentColor.identity(for: name.lowercased()) == .coral
                ? .violet : DockAccentColor.identity(for: name.lowercased())
        }
    }
}

private struct SessionTraceHatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: -rect.height, through: rect.width, by: 7) {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
        }
        return path
    }
}

/// Trackpad/wheel navigation must release follow just like dragging the scrollbar.
@MainActor final class SessionTraceScroll: ObservableObject {
    @Published var x: CGFloat = 0
    weak var host: NSView?

    func reveal(_ bar: SessionTraceBarLayout) {
        guard let scroll = host?.enclosingScrollView, let document = scroll.documentView,
            let x = bar.revealOffset(in: scroll.contentView.bounds, contentWidth: document.bounds.width)
        else { return }
        move(to: x, in: scroll)
    }

    func reset() {
        guard let scroll = host?.enclosingScrollView else { return }
        move(to: 0, in: scroll)
    }

    private func move(to x: CGFloat, in scroll: NSScrollView) {
        scroll.contentView.scroll(to: NSPoint(x: x, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// Observes horizontal position only where drawing depends on it.
private struct SessionTraceScrolled<Content: View>: View {
    @ObservedObject var scroll: SessionTraceScroll
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View { content(scroll.x) }
}

/// Reads the native horizontal scroll position (programmatic scrolls included)
/// and reports user wheel scrolling on either axis, which turns Live off.
private struct SessionTraceScrollObserver: NSViewRepresentable {
    let scroll: SessionTraceScroll?
    let onUserScroll: () -> Void
    func makeNSView(context: Context) -> Observer {
        let view = Observer()
        view.scroll = scroll
        view.onUserScroll = onUserScroll
        return view
    }
    func updateNSView(_ view: Observer, context: Context) {
        view.scroll = scroll
        view.onUserScroll = onUserScroll
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: NSView {
        var scroll: SessionTraceScroll?
        var onUserScroll: (() -> Void)?
        private var monitor: Any?
        private var boundsObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
                report()
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                if let self, let window = self.window, event.window === window,
                    let clip = self.enclosingScrollView,
                    clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)),
                    abs(event.scrollingDeltaX) > 0 || abs(event.scrollingDeltaY) > 0,
                    event.momentumPhase.isEmpty
                {
                    self.onUserScroll?()
                }
                return event
            }
        }
        private func report() {
            guard let clip = enclosingScrollView?.contentView, let scroll else { return }
            scroll.host = self
            let x = max(0, clip.bounds.origin.x)
            if abs(scroll.x - x) > 0.25 { scroll.x = x }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            monitor = nil
            boundsObserver = nil
        }
    }
}
