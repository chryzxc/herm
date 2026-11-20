import SwiftUI
import UniformTypeIdentifiers

/// What the document should do after a map action hands control back to it.
enum SpecMapFocus: Equatable {
    case reveal(String)
    case comment(String)
    /// Opens a saved review note in place.
    case note(UUID)
}

extension SpecMapStatus {
    var tone: DockStatusTone {
        switch self {
        case .todo: .inactive
        case .inProgress: .working
        case .done: .complete
        case .blocked: .attention
        }
    }

    var label: String {
        switch self {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .done: "Done"
        case .blocked: "Blocked"
        }
    }
}

/// Everything a map shows on top of the document's own structure, all from live state.
struct SpecMapOverlay: Equatable {
    /// Titles of nodes Hermes added or changed since they were last looked at.
    var updated: Set<String> = []
    /// Unsent review notes whose quote falls in a node, by node id.
    var notes: [String: [UUID]] = [:]
    /// The session's task list matched to nodes.
    var live: [String: SpecMapLiveStatus] = [:]
}

/// What the map hands back to its pane; the view itself never persists, sends or opens.
struct SpecMapActions {
    var reveal: (SpecMapNode) -> Void = { _ in }
    var comment: (SpecMapNode) -> Void = { _ in }
    var send: ([SpecMapNode]) -> Void = { _ in }
    var openNote: (UUID) -> Void = { _ in }
    var seen: (SpecMapNode) -> Void = { _ in }
    var openFile: (URL) -> Void = { _ in }
    var resolveFile: (String) -> URL? = { _ in nil }
}

/// Fold state per file, a local preference. ponytail: ids follow source lines, so a fold
/// can move to a neighbour after a large edit above it; key by title path if that bites.
enum SpecMapFolds {
    private static let key = "herm.specMapFolds.v1"
    private static let limit = 40

    static func load(_ path: String) -> Set<String> {
        Set((UserDefaults.standard.dictionary(forKey: key) as? [String: [String]])?[path] ?? [])
    }

    static func save(_ ids: Set<String>, for path: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[path] = ids.isEmpty ? nil : ids.sorted()
        // ponytail: drops an arbitrary file past the cap; order by last use if that matters.
        while all.count > limit, let first = all.keys.first(where: { $0 != path }) { all[first] = nil }
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// A plan drawn as a node graph on a plain canvas that pans both ways. As a
/// tree (the default), the document's title is the root and every node's
/// children branch out to its right; as a list, phases stack top to bottom with
/// steps indented under them. Stated dependencies are drawn
/// as dashed wires between steps, across phases too, and each dependent step
/// says whether it is ready. Selecting a step expands it in place with its
/// notes and actions; ⌘-click picks several to send together. Actions go out
/// through closures; the view owns only selection, folds, search and frames.
struct SpecMapView: View, Equatable {
    let map: SpecMap
    @Binding var selectedID: String?
    /// The file path folds are remembered under; nil keeps them for this view only.
    var storageKey: String?
    var overlay = SpecMapOverlay()
    var actions = SpecMapActions()
    var isExpanded = false

    /// Actions are left out: they are closures over the pane's state, so a token stream
    /// that re-runs the pane would otherwise re-run the whole map every time.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.map == rhs.map && lhs._selectedID.wrappedValue == rhs._selectedID.wrappedValue
            && lhs.storageKey == rhs.storageKey && lhs.overlay == rhs.overlay && lhs.isExpanded == rhs.isExpanded
    }

    @State private var collapsed: Set<String> = []
    @State private var picked: Set<String> = []
    @State private var showingExpanded = false
    @State private var showsSearch = false
    @State private var query = ""
    @State private var scrollTarget: String?
    /// Pan and zoom of the canvas; it starts below the pane's floating top controls.
    @State private var viewport = SpecMapViewport(pan: CGSize(width: 0, height: ToolsTopFade.reserved))
    @State private var dragStart: CGSize?
    @State private var canvasSize: CGSize = .zero
    @State private var paneSize: CGSize = .zero
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isMapFocused: Bool
    /// A tree branches right to show the plan's shape; a list suits a narrow pane and long text.
    @AppStorage(Self.layoutKey) private var isTree = true
    /// Node frames in the canvas space, keyed `root`, `phase:`, `card:` and `head:`.
    @State private var frames: [String: CGRect] = [:]
    /// The hovered node lights up its dependency wires, like selection does. Held outside
    /// view state so a hover, which fires on every card the pointer crosses while scrolling,
    /// redraws only the wires instead of every card.
    @State private var hover = SpecMapHover()
    /// Search results, recomputed when the query or map changes rather than per row.
    @State private var search = Search()
    /// The open node's file chips, resolved on disk once per selection rather than per render.
    @State private var openFiles: [(path: String, url: URL)] = []

    private struct Search {
        var matches: [SpecMapNode] = []
        /// Matches plus every ancestor, so the path to a match never fades; nil with no query.
        var relevant: Set<String>?
        /// Ancestors of a match (never the match itself): folding one hides that match.
        var aboveMatches: Set<String> = []
    }

    fileprivate static let space = "spec-canvas"
    static let layoutKey = "herm.specMapTree.v1"

    private enum Metrics {
        static let inset: CGFloat = 28
        static let columnGap: CGFloat = 84
        static let columnWidth: CGFloat = 440
        /// Tree cards stay narrow so branches fit across; the open card widens for its notes.
        static let cardWidth: CGFloat = 280
        static let openCardWidth: CGFloat = 440
        static let branchGap: CGFloat = 56
        static let rootWidth: CGFloat = 240
        static let rowGap: CGFloat = 10
        static let phaseGap: CGFloat = 40
        static let loop: CGFloat = 24
        /// Room under a card for its junction before its first child.
        static let levelGap: CGFloat = 22
        static let indent: CGFloat = 36
        static let trunk: CGFloat = 18
        static let corner: CGFloat = 12
        static let socket: CGFloat = 7
        static let port: CGFloat = 18
    }

    private var showsRoot: Bool { map.lanes.count > 1 }

    var body: some View {
        // Nodes keep their natural size; the canvas pans by dragging and zooms with scroll or pinch.
        GeometryReader { geometry in
            canvas
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: \.size) { canvasSize = $0 }
                .scaleEffect(viewport.zoom, anchor: .topLeading)
                .offset(viewport.pan)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background { panSurface }
                .overlay { SpecMapZoomInput { zoom(by: $0, at: $1) }.allowsHitTesting(false) }
                .clipped()
                .background { SpecMapGrid(viewport: viewport) }
                .onAppear { paneSize = geometry.size }
                .onChange(of: geometry.size) { _, size in
                    paneSize = size
                    clampViewport()
                }
        }
        .focusable()
        .focused($isMapFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handle)
        .onCopyCommand { selectedNode.map { [NSItemProvider(object: copyText($0) as NSString)] } ?? [] }
        .onChange(of: scrollTarget) { _, id in
            guard let id else { return }
            scrollTarget = nil
            revealNow(id)
        }
        .onChange(of: canvasSize) { clampViewport() }
        .overlay(alignment: .top) { ToolsTopFade() }
        .overlay(alignment: .topLeading) { floatingPanels }
        .overlay(alignment: .topTrailing) { toolbar }
        .onAppear {
            if let storageKey { collapsed = SpecMapFolds.load(storageKey) }
            if let selectedID { reveal(selectedID) }
        }
        .onChange(of: collapsed) { _, ids in if let storageKey { SpecMapFolds.save(ids, for: storageKey) } }
        .onChange(of: map) { old, map in
            // Ids follow lines: carry selection, picks and folds by title when text moved.
            selectedID = selectedID.flatMap { map.matching($0, from: old) }.flatMap { map.node($0)?.id }
            picked = Set(picked.compactMap { map.matching($0, from: old) }.filter { map.node($0) != nil })
            collapsed = Set(collapsed.compactMap { map.matching($0, from: old) })
            refreshSearch()
            resolveOpenFiles()
        }
        .onChange(of: query) { refreshSearch() }
        .onChange(of: selectedID, initial: true) { resolveOpenFiles() }
        .dockSheet(isPresented: $showingExpanded) {
            DockExpandedPage(title: map.title, subtitle: "Plan", close: { showingExpanded = false }) {
                SpecMapView(
                    map: map, selectedID: $selectedID, storageKey: storageKey, overlay: overlay,
                    actions: leavingFullScreen, isExpanded: true)
            }
            .frame(minWidth: 900, minHeight: 640)
            .modifier(ReviewSheetContext())
        }
    }

    /// Actions that hand control back to the document leave full screen first.
    private var leavingFullScreen: SpecMapActions {
        var result = actions
        let close = { showingExpanded = false }
        result.reveal = {
            close()
            actions.reveal($0)
        }
        result.comment = {
            close()
            actions.comment($0)
        }
        result.send = {
            close()
            actions.send($0)
        }
        result.openNote = {
            close()
            actions.openNote($0)
        }
        result.openFile = {
            close()
            actions.openFile($0)
        }
        return result
    }

    private var canvas: some View {
        Group {
            if isTree { treeLayout } else { listLayout }
        }
        .dockPadding(Metrics.inset)
        // Stacked phases chain down the left side, so leave room for that loop.
        .dockPadding(.leading, isTree ? 0 : Metrics.loop)
        .coordinateSpace(.named(Self.space))
        .background { wires }
    }

    /// Phases stacked top to bottom, each an indented list under its phase card.
    private var listLayout: some View {
        VStack(alignment: .leading, spacing: Metrics.phaseGap) {
            if showsRoot { root }
            ForEach(Array(map.lanes.enumerated()), id: \.element.id) { index, lane in
                column(lane, index: index)
            }
        }
    }

    /// Every node's children branch out to its right, centred on it. One phase is its own root.
    @ViewBuilder
    private var treeLayout: some View {
        if showsRoot {
            branch(root, isOpen: true) {
                ForEach(Array(map.lanes.enumerated()), id: \.element.id) { index, lane in
                    laneBranch(lane, index: index)
                }
            }
        } else if let lane = map.lanes.first {
            laneBranch(lane, index: 0)
        }
    }

    private func branch<Card: View, Children: View>(
        _ card: Card, isOpen: Bool, @ViewBuilder children: () -> Children
    ) -> some View {
        HStack(alignment: .center, spacing: Metrics.branchGap) {
            card
            if isOpen { VStack(alignment: .leading, spacing: Metrics.rowGap) { children() } }
        }
    }

    private func laneBranch(_ lane: SpecMapLane, index: Int) -> some View {
        let isOpen = !collapsed.contains(lane.id)
        return branch(
            phase(lane, index: index, isOpen: isOpen).frame(width: Metrics.cardWidth),
            isOpen: isOpen && !lane.nodes.isEmpty
        ) {
            ForEach(Array(lane.nodes.enumerated()), id: \.element.id) { index, node in
                nodeBranch(node, in: lane, index: index + 1)
            }
        }
    }

    /// Recursion needs a concrete type; nesting depth is the document's.
    private func nodeBranch(_ node: SpecMapNode, in lane: SpecMapLane, index: Int?) -> AnyView {
        let children = lane.children(of: node.id)
        let isOpen = !collapsed.contains(node.id)
        return AnyView(
            branch(
                row(node, index: index, children: children.count, isOpen: isOpen)
                    .frame(width: node.id == selectedID ? Metrics.openCardWidth : Metrics.cardWidth),
                isOpen: isOpen && !children.isEmpty
            ) {
                ForEach(children) { child in nodeBranch(child, in: lane, index: nil) }
            })
    }

    /// Only real moves write: every write re-runs body, and geometry reports repeat values.
    private func store(_ key: String, _ frame: CGRect) { if frames[key] != frame { frames[key] = frame } }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            let updated = orderedNodes.filter { overlay.updated.contains($0.title) }
            if let first = updated.first {
                Button {
                    select(first.id)
                } label: {
                    DockIconLabel("\(updated.count) updated", icon: .clockCounterClockwise)
                }
                .buttonStyle(.dockSecondary)
                .help(
                    "Select the next step whose text Hermes changed since you last opened this plan. The count clears as you view each one."
                )
                .dockPadding(.trailing, 2)
            }
            if let next = map.nextUp {
                DockIconAction(
                    icon: .arrowCircleRight, label: "Jump to next step: \(next.title)",
                    help: "Jump to Next up: \(next.title). It is the first open step with nothing left to wait on."
                ) {
                    select(next.id)
                }
            }
            DockIconAction(
                icon: .magnifyingGlass, label: "Find in plan (⌘F)",
                help: "Find in plan (⌘F). Fades steps that don’t match and opens folded branches that do.",
                isProminent: showsSearch
            ) {
                showsSearch ? closeSearch() : openSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            DockMenu(outlined: true, content: { moreMenu }) {
                DockIcon(.dotsThree, size: 14)
            }
            .dockIconOnlyAction()
            .help(
                "Plan actions: expand or collapse every step, show only phases or steps, or copy the plan as a Markdown outline with its statuses."
            )
            .accessibilityLabel("More plan actions")
            DockIconAction(
                icon: isTree ? .listBullets : .treeStructure,
                label: isTree ? "Show as list" : "Show as tree",
                help: isTree
                    ? "Show as list: phases stacked top to bottom with each step indented under its parent. Suits a narrow pane and long step text."
                    : "Show as tree: each step’s nested items branch out to its right, so you see the plan’s shape at a glance. Fold a branch with the port on its card’s edge."
            ) {
                withAnimation(.dockEase(duration: 0.25)) { isTree.toggle() }
            }
            if !isExpanded {
                DockIconAction(
                    icon: .arrowsOut, label: "Open plan full screen",
                    help:
                        "Open this plan in a full-window view with more room for wide phases. Close it to return here."
                ) {
                    showingExpanded = true
                }
            }
        }
        .dockButtonSize(.compact)
        .dockPadding(10)
    }

    @ViewBuilder
    private var moreMenu: some View {
        Button {
            fold([])
        } label: {
            Label("Expand all", icon: .arrowsOutLineVertical)
        }
        Button {
            fold(
                Set(map.lanes.flatMap { lane in lane.allNodes.filter { !lane.children(of: $0.id).isEmpty } }.map(\.id)))
        } label: {
            Label("Show steps only", icon: .listBullets)
        }
        Button {
            fold(Set(map.lanes.map(\.id)))
        } label: {
            Label("Collapse to phases", icon: .arrowsInLineVertical)
        }
        Divider()
        Button {
            zoom(to: viewport.zoom * 1.25)
        } label: {
            Label("Zoom in", icon: .magnifyingGlassPlus)
        }
        .disabled(!viewport.canZoomIn)
        Button {
            zoom(to: viewport.zoom / 1.25)
        } label: {
            Label("Zoom out", icon: .magnifyingGlassMinus)
        }
        .disabled(!viewport.canZoomOut)
        Button {
            zoom(to: 1)
        } label: {
            Label("Actual size (\(Int((viewport.zoom * 100).rounded()))%)", icon: .arrowCounterClockwise)
        }
        .disabled(abs(viewport.zoom - 1) < 0.001)
        Divider()
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(map.outline, forType: .string)
        } label: {
            Label("Copy as outline", icon: .copy)
        }
    }

    private func fold(_ ids: Set<String>) {
        withAnimation(.dockEase(duration: 0.2)) { collapsed = ids }
    }

    // MARK: Search and multi-select

    @ViewBuilder
    private var floatingPanels: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSearch { searchField }
            if picked.count > 1 { pickedBar }
        }
        .dockPadding(10)
    }

    private var searchField: some View {
        let matches = search.matches
        return HStack(spacing: 8) {
            DockIcon(.magnifyingGlass, size: 13, color: Color.dockMetadataText)
            TextField("Find in map", text: $query)
                .textFieldStyle(.plain)
                .dockFont(.body)
                .focused($isSearchFocused)
                .onSubmit(nextMatch)
                .onExitCommand(perform: closeSearch)
            if !query.isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(matches.count) found")
                    .dockFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize()
            }
            Button(action: closeSearch) {
                DockIcon(.x, size: 12, color: Color.dockMetadataText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .dockPointerCursor()
            .help("Close find (Esc)")
            .accessibilityLabel("Close find")
        }
        .frame(width: 280)
        .dockCard(padding: 8, isSolid: true)
        .help("Return jumps to the next match")
    }

    private var pickedBar: some View {
        HStack(spacing: 8) {
            Text("\(picked.count) selected")
                .dockFont(.metadata, weight: .medium)
                .foregroundStyle(Color.dockSecondaryText)
            Button("Clear") { picked = [] }
                .buttonStyle(.dockSecondary)
                .help("Clear the multi-selection. ⌘-click steps to pick them again.")
            Button {
                actions.send(orderedNodes.filter { picked.contains($0.id) })
                picked = []
            } label: {
                DockIconLabel("Send \(picked.count) to chat", icon: .paperPlaneTilt)
            }
            .buttonStyle(.dockPrimary)
            .help(
                "Add the selected steps to the chat composer as one context chip, so you can ask Hermes about them together. Nothing is sent until you send."
            )
        }
        .dockButtonSize(.compact)
        .fixedSize()
        .dockCard(padding: 8, isSolid: true)
    }

    private func openSearch() {
        showsSearch = true
        DispatchQueue.main.async { isSearchFocused = true }
    }

    private func closeSearch() {
        showsSearch = false
        query = ""
        isMapFocused = true
    }

    private var orderedNodes: [SpecMapNode] { map.ordered }
    private var relevant: Set<String>? { search.relevant }

    private func refreshSearch() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            search = Search()
            return
        }
        var result = Search(relevant: [])
        result.matches = map.ordered.filter {
            "\($0.label ?? "") \($0.title) \($0.summary ?? "") \($0.detail)".lowercased().contains(needle)
        }
        for match in result.matches {
            result.relevant?.insert(match.id)
            var parent = match.parentID
            while let id = parent, result.aboveMatches.insert(id).inserted {
                result.relevant?.insert(id)
                parent = map.node(id)?.parentID
            }
        }
        search = result
    }

    private func resolveOpenFiles() {
        openFiles =
            selectedNode.map { node in
                SpecMapParser.filePaths(in: node.detail).compactMap { path in
                    actions.resolveFile(path).map { (path, $0) }
                }
            } ?? []
    }

    private func nextMatch() {
        let matches = search.matches
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selectedID }
        let next = matches[current.map { ($0 + 1) % matches.count } ?? 0]
        select(next.id)
    }

    /// Selects a node, unfolding the way to it, and scrolls it into view.
    private func select(_ id: String) {
        withAnimation(.dockEase(duration: 0.2)) {
            var node = map.node(id)
            while let current = node, let parent = current.parentID {
                collapsed.remove(parent)
                node = map.node(parent)
            }
            if let lane = map.lane(of: id) { collapsed.remove(lane.id) }
            selectedID = id
        }
        if let node = map.node(id) { actions.seen(node) }
        reveal(id)
    }

    private func reveal(_ id: String) {
        DispatchQueue.main.async { scrollTarget = id }
    }

    // MARK: Pan and zoom

    /// Clear of the pane's floating controls: the top fade, and the view controls along the bottom.
    private var revealInsets: EdgeInsets {
        EdgeInsets(top: ToolsTopFade.reserved, leading: 12, bottom: isExpanded ? 12 : 48, trailing: 12)
    }

    private func revealNow(_ id: String) {
        guard let rect = frames["card:\(id)"] ?? frames["phase:\(id)"] else { return }
        withAnimation(.dockEase(duration: 0.2)) {
            viewport = viewport.revealing(rect, in: paneSize, insets: revealInsets)
        }
    }

    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        viewport = viewport.zoomed(by: factor, at: anchor).clamped(content: canvasSize, in: paneSize)
    }

    private func zoom(to level: CGFloat) {
        let center = CGPoint(x: paneSize.width / 2, y: paneSize.height / 2)
        withAnimation(.dockEase(duration: 0.2)) { zoom(by: level / viewport.zoom, at: center) }
    }

    private func clampViewport() {
        let clamped = viewport.clamped(content: canvasSize, in: paneSize)
        if clamped != viewport { viewport = clamped }
    }

    /// The empty canvas behind the cards: grab it to pan. Cards and controls keep their clicks.
    private var panSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = viewport.pan
                            NSCursor.closedHand.push()
                        }
                        guard let start = dragStart else { return }
                        var next = viewport
                        next.pan = CGSize(
                            width: start.width + value.translation.width,
                            height: start.height + value.translation.height)
                        viewport = next.clamped(content: canvasSize, in: paneSize)
                    }
                    .onEnded { _ in
                        if dragStart != nil { NSCursor.pop() }
                        dragStart = nil
                    }
            )
            .accessibilityHidden(true)
    }

    // MARK: Keyboard

    private var selectedNode: SpecMapNode? { selectedID.flatMap { map.node($0) } }

    /// Nodes in reading order, skipping folded branches.
    private var visibleOrder: [SpecMapNode] {
        map.lanes.filter { !collapsed.contains($0.id) }.flatMap { lane in
            func walk(_ nodes: [SpecMapNode]) -> [SpecMapNode] {
                nodes.flatMap { [$0] + (collapsed.contains($0.id) ? [] : walk(lane.children(of: $0.id))) }
            }
            return walk(lane.nodes)
        }
    }

    private func hasChildren(_ node: SpecMapNode) -> Bool {
        map.lanes.contains { !$0.children(of: node.id).isEmpty }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let order = visibleOrder
        let index = order.firstIndex { $0.id == selectedID }
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .downArrow, .upArrow:
            guard !order.isEmpty else { return .ignored }
            let step = press.key == .downArrow ? 1 : -1
            let next = index.map { min(max($0 + step, 0), order.count - 1) } ?? 0
            select(order[next].id)
        case .rightArrow:
            guard let node = selectedNode, hasChildren(node) else { return .ignored }
            if collapsed.contains(node.id) {
                fold(collapsed.subtracting([node.id]))
            } else if let index, index + 1 < order.count {
                select(order[index + 1].id)
            }
        case .leftArrow:
            guard let node = selectedNode else { return .ignored }
            if hasChildren(node), !collapsed.contains(node.id) {
                fold(collapsed.union([node.id]))
            } else if let parent = node.parentID {
                select(parent)
            }
        case .return:
            guard let node = selectedNode else { return .ignored }
            actions.reveal(node)
        case .escape:
            if !picked.isEmpty {
                picked = []
            } else if selectedID != nil {
                withAnimation(.dockEase(duration: 0.2)) { selectedID = nil }
            } else {
                return .ignored
            }
        default:
            return .ignored
        }
        return .handled
    }

    private func copyText(_ node: SpecMapNode) -> String {
        let notes = notes(of: node)
        return ([node.title, node.summary].compactMap(\.self) + (notes.isEmpty ? [] : [notes]))
            .joined(separator: "\n\n")
    }

    private func notes(of node: SpecMapNode) -> String {
        map.lane(of: node.id)?.notes(of: node) ?? ""
    }

    // MARK: Pipeline

    private var root: some View {
        let steps = map.lanes.flatMap(\.nodes)
        // Only steps with a stated status count, as in the header's progress.
        return HStack(spacing: 12) {
            if let progress = map.progress { ProgressRing(done: progress.done, total: progress.total, isActive: false) }
            VStack(alignment: .leading) {
                Text("Plan").dockFont(.machineMetadata).foregroundStyle(Color.dockMetadataText)
                Text(map.title)
                    .dockFont(.rowTitle, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(map.lanes.count) phases · \(steps.count) steps")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 14, isSolid: true)
        .frame(width: Metrics.rootWidth)
        .specFrame("root", store)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(map.title), \(map.lanes.count) phases, \(steps.count) steps"
                + (map.progress.map { ", \($0.done) of \($0.total) done" } ?? ""))
    }

    private func column(_ lane: SpecMapLane, index: Int) -> some View {
        let isOpen = !collapsed.contains(lane.id)
        return VStack(alignment: .leading, spacing: Metrics.levelGap) {
            phase(lane, index: index, isOpen: isOpen)
            if isOpen, !lane.nodes.isEmpty { tree(lane.nodes, in: lane, numbered: true) }
        }
        .frame(width: Metrics.columnWidth, alignment: .leading)
    }

    private func phase(_ lane: SpecMapLane, index: Int, isOpen: Bool) -> some View {
        let holdsSelection = selectedID.flatMap { map.lane(of: $0)?.id } == lane.id
        let isMuted = SpecMapSectionTone(title: lane.title) == .muted
        return HStack(spacing: 12) {
            if lane.statedCount > 0 {
                ProgressRing(done: lane.doneCount, total: lane.statedCount, isActive: holdsSelection)
            }
            VStack(alignment: .leading) {
                if showsRoot {
                    Text("Phase \(index + 1)").dockFont(.machineMetadata).foregroundStyle(Color.dockMetadataText)
                }
                Text(lane.title)
                    .dockFont(.rowTitle, weight: .semibold)
                    .foregroundStyle(isMuted ? Color.dockSecondaryText : Color.dockPrimaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                summary(lane)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 14, isActive: holdsSelection, tint: holdsSelection ? Color.dockAccent : nil, isSolid: true)
        .opacity(relevant.map { ids in lane.allNodes.contains { ids.contains($0.id) } } ?? true ? 1 : 0.4)
        .specFrame("phase:\(lane.id)", store)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(lane.title)" + (lane.statedCount > 0 ? ", \(lane.doneCount) of \(lane.statedCount) done" : "")
        )
        .overlay(alignment: isTree ? .topTrailing : .bottomLeading) {
            if !lane.nodes.isEmpty {
                port(
                    lane.id, title: lane.title, count: lane.nodes.count, isOpen: isOpen,
                    headHeight: frames["phase:\(lane.id)"]?.height)
            }
        }
    }

    /// Step count plus only the statuses that call for attention.
    private func summary(_ lane: SpecMapLane) -> some View {
        let working = lane.nodes.count { $0.status == .inProgress }
        let blocked = lane.nodes.count { $0.status == .blocked }
        return HStack(spacing: 6) {
            Text(lane.nodes.count == 1 ? "1 step" : "\(lane.nodes.count) steps")
                .foregroundStyle(Color.dockMetadataText)
            if working > 0 {
                Text("\(working) active").foregroundStyle(DockStatusTone.working.color)
            }
            if blocked > 0 {
                Text("\(blocked) blocked").foregroundStyle(DockStatusTone.attention.color)
            }
        }
        .dockFont(.metadata)
        .lineLimit(1)
    }

    /// The fold port, placed where the node's wires leave it: hung under the card in a list,
    /// on its right edge at the header's middle in a tree.
    @ViewBuilder
    private func port(_ id: String, title: String, count: Int, isOpen: Bool, headHeight: CGFloat?) -> some View {
        let junction = junction(id, title: title, count: count, isOpen: isOpen)
        if isTree {
            junction.offset(x: Metrics.port + 4, y: (headHeight ?? 44) / 2 - Metrics.port / 2)
        } else {
            // Centered on the trunk, its top on the card's bottom edge. An offset, not alignment
            // guides: overlays placed this port inside the card when it used guides.
            junction.offset(x: Metrics.trunk - Metrics.port / 2, y: Metrics.port)
        }
    }

    private func junction(_ id: String, title: String, count: Int, isOpen: Bool) -> some View {
        let items = count == 1 ? "1 item" : "\(count) items"
        let label = isOpen ? "Collapse \(title)" : "Show \(count) under \(title)"
        let help =
            isOpen
            ? "Fold \(title): hide the \(items) under it. Folds are remembered for this file."
            : "Unfold \(title): show the \(items) under it."
        return Button {
            fold(isOpen ? collapsed.union([id]) : collapsed.subtracting([id]))
        } label: {
            // An output port hung under the card's bottom edge, drawn like the tree it folds: an
            // open socket in the line color. Hanging below keeps it clear of the card's text.
            DockIcon(isOpen ? .minus : .plus, size: 10, color: Color.dockSecondaryText)
                .frame(width: Metrics.port, height: Metrics.port)
                .background(Circle().fill(Color.dockCanvas))
                .overlay(Circle().stroke(Color.dockBorderStrong, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.dockHover)
        .dockPointerCursor()
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: Tree

    private func tree(_ nodes: [SpecMapNode], in lane: SpecMapLane, numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                let children = lane.children(of: node.id)
                let isOpen = !collapsed.contains(node.id)
                VStack(alignment: .leading, spacing: Metrics.levelGap) {
                    row(node, index: numbered ? index + 1 : nil, children: children.count, isOpen: isOpen)
                    if isOpen, !children.isEmpty {
                        // Recursion needs a concrete type; nesting depth is the document's.
                        AnyView(tree(children, in: lane, numbered: false))
                    }
                }
                // A folded card's port hangs into the gap below it.
                .dockPadding(.bottom, !children.isEmpty && !isOpen ? Metrics.port : 0)
            }
        }
        .dockPadding(.leading, Metrics.indent)
    }

    private func row(_ node: SpecMapNode, index: Int?, children: Int, isOpen: Bool) -> some View {
        let isSelected = node.id == selectedID
        let isPicked = picked.contains(node.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                click(node)
            } label: {
                header(node, index: index, children: children, isOpen: isOpen)
            }
            .buttonStyle(.dockHover)
            .specFrame("head:\(node.id)", store)
            .accessibilityLabel(
                [node.label, node.title, node.status?.label].compactMap(\.self).joined(separator: ", ")
            )
            .accessibilityValue(node.subtasksTotal > 0 ? "\(node.subtasksDone) of \(node.subtasksTotal) subtasks" : "")
            .accessibilityAddTraits(isSelected || isPicked ? .isSelected : [])
            .accessibilityHint("Command-click to pick several steps")
            if isSelected { expanded(node) }
        }
        .dockCard(
            padding: 0, isActive: isSelected || isPicked, tint: isSelected || isPicked ? Color.dockAccent : nil,
            isSolid: true
        )
        .opacity(relevant.map { $0.contains(node.id) } ?? true ? 1 : 0.35)
        .specFrame("card:\(node.id)", store)
        .id(node.id)
        .onHover { inside in
            if inside {
                hover.id = node.id
            } else if hover.id == node.id {
                hover.id = nil
            }
        }
        .overlay(alignment: isTree ? .topTrailing : .bottomLeading) {
            if children > 0 {
                port(
                    node.id, title: node.title, count: children, isOpen: isOpen,
                    headHeight: frames["head:\(node.id)"]?.height)
            }
        }
    }

    /// Click selects; ⌘-click picks several steps to send together.
    private func click(_ node: SpecMapNode) {
        isMapFocused = true
        if NSEvent.modifierFlags.contains(.command) {
            var next = picked
            if next.isEmpty, let selectedID { next.insert(selectedID) }
            next.formSymmetricDifference([node.id])
            picked = next
            return
        }
        picked = []
        if node.id == selectedID {
            withAnimation(.dockEase(duration: 0.2)) { selectedID = nil }
        } else {
            withAnimation(.dockEase(duration: 0.2)) { selectedID = node.id }
            actions.seen(node)
        }
    }

    private func header(_ node: SpecMapNode, index: Int?, children: Int, isOpen: Bool) -> some View {
        let isSelected = node.id == selectedID
        let isMuted = SpecMapSectionTone(title: node.title) == .muted
        let summary = node.summary ?? (isSelected ? nil : node.preview)
        let text = VStack(alignment: .leading, spacing: 2) {
            Text(Self.displayTitle(node.title))
                .dockFont(.body, weight: index == nil ? .regular : .medium)
                .foregroundStyle(node.status == .done || isMuted ? Color.dockSecondaryText : Color.dockPrimaryText)
                .lineLimit(isSelected ? 6 : 2)
            if let summary {
                Text(summary)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(isSelected ? 8 : 1)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        // Only a cut-off summary needs a tooltip; one that repeats the title adds a tip per card crossed.
        .modifier(SpecMapTruncatedTip(text: summary.map { "\(node.title)\n\n\($0)" }))
        let trailing = HStack(spacing: 6) {
            meta(node, children: isOpen ? 0 : children)
            DockIcon(isSelected ? .caretDown : .caretRight, size: 11, color: Color.dockMetadataText)
        }
        // A step gets a label strip (status, number, badges) over a full-width title, so narrow
        // cards fit; a nested item keeps one compact row.
        return Group {
            if let index {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        marker(node, size: 12)
                        // Under phases the top level is steps; a single-phase outline's are its sections.
                        Text(String(format: showsRoot ? "STEP %02d" : "%02d", index))
                            .dockFont(.machineMetadata)
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.dockAccent : Color.dockMetadataText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        trailing
                    }
                    text
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    marker(node, size: 14).dockPadding(.top, 1)
                    text
                    Spacer(minLength: 8)
                    trailing.dockPadding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockPadding(.horizontal, 12)
        .dockPadding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// A file path reads by its filename; the full path stays in the tooltip and file chip.
    static func displayTitle(_ title: String) -> String {
        guard !title.contains(" "), title.contains("/"), SpecMapParser.filePaths(in: title).first == title else {
            return title
        }
        return (title as NSString).lastPathComponent
    }

    private func sources(of node: SpecMapNode) -> [SpecMapNode] {
        map.sources(of: node.id)
    }

    /// Whether a folded branch hides a search match.
    private func hidesMatch(_ node: SpecMapNode) -> Bool {
        collapsed.contains(node.id) && search.aboveMatches.contains(node.id)
    }

    /// Live and review state first, then status, ID, progress, readiness and folded children.
    private func meta(_ node: SpecMapNode, children: Int) -> some View {
        let sources = sources(of: node)
        let waiting = sources.count { $0.status != .done }
        let notes = overlay.notes[node.id]?.count ?? 0
        return HStack(spacing: 8) {
            if node.id == map.nextUp?.id {
                DockIconLabel("Next up", icon: .arrowCircleRight)
                    .dockFont(.metadata, weight: .medium)
                    .foregroundStyle(Color.dockAccent)
                    .help("Next up: the first open step with nothing left to wait on. The toolbar’s arrow jumps here.")
            }
            if overlay.updated.contains(node.title) {
                Text("Updated")
                    .dockFont(.metadata, weight: .medium)
                    .foregroundStyle(Color.dockAccent)
                    .help("Hermes changed this step in the file since you last opened it. Selecting it marks it seen.")
            }
            switch overlay.live[node.id] {
            case .working:
                DockIconLabel("Working", icon: .circleHalf)
                    .dockFont(.metadata)
                    .foregroundStyle(DockStatusTone.working.color)
                    .help("The session’s task list has this step in progress, so the agent is working on it now.")
            case .done:
                Text("Done in chat")
                    .dockFont(.metadata)
                    .foregroundStyle(DockStatusTone.complete.color)
                    .help("The session’s task list marks this step done. The plan file itself is not ticked.")
            case nil:
                EmptyView()
            }
            if notes > 0 {
                DockIconLabel("\(notes)", icon: .chatCircleText)
                    .dockFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Color.dockAccent)
                    .help(
                        (notes == 1 ? "1 unsent note quotes" : "\(notes) unsent notes quote")
                            + " this step. Open it from the step’s footer; notes go to Hermes with your review.")
            }
            if hidesMatch(node) {
                DockIcon(.magnifyingGlass, size: 11, color: Color.dockAccent)
                    .help("A find match is folded inside. Unfold this step to see it.")
            }
            if let status = node.status, status != .todo {
                Text(status.label).dockFont(.metadata).foregroundStyle(status.tone.color)
                    .help("\(status.label), as the plan file marks it.")
            }
            if !sources.isEmpty, node.status != .done {
                if waiting == 0 {
                    DockIconLabel("Ready", icon: .lightning)
                        .dockFont(.metadata)
                        .foregroundStyle(DockStatusTone.complete.color)
                        .help("Ready: every step this depends on is done, so it can start.")
                } else {
                    DockIconLabel("\(waiting)", icon: .lockSimple)
                        .dockFont(.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                        .help(
                            (waiting == 1 ? "Waiting on 1 step" : "Waiting on \(waiting) steps")
                                + " this depends on. Select it to see which.")
                }
            }
            if let label = node.label {
                Text(label).dockFont(.compactStatus, weight: .medium).dockPill(compact: true)
                    .help("\(label) is this step’s ID in the plan; other steps name it when they depend on it.")
            }
            if node.subtasksTotal > 0 {
                Text("\(node.subtasksDone)/\(node.subtasksTotal)")
                    .dockFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Color.dockMetadataText)
                    .help("\(node.subtasksDone) of \(node.subtasksTotal) subtasks done")
            }
            if children > 0 {
                DockIconLabel("\(children)", icon: .treeStructure)
                    .dockFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Color.dockMetadataText)
                    .help(
                        (children == 1 ? "1 nested item is" : "\(children) nested items are")
                            + " folded under this step. Use its fold port to show them.")
            }
        }
        .lineLimit(1)
        .fixedSize()
        .dockPadding(.top, 1)
    }

    /// Status icon when the document states one; otherwise what the heading says it is.
    @ViewBuilder
    private func marker(_ node: SpecMapNode, size: CGFloat) -> some View {
        switch node.status {
        case .done: DockIcon(.checkCircle, size: size, weight: .fill, color: DockStatusTone.complete.color)
        case .inProgress: DockIcon(.circleHalf, size: size, weight: .fill, color: DockStatusTone.working.color)
        case .blocked: DockIcon(.warningCircle, size: size, weight: .fill, color: DockStatusTone.attention.color)
        case .todo: DockIcon(.circle, size: size, color: Color.dockMetadataText)
        case nil:
            switch SpecMapSectionTone(title: node.title) {
            case .attention: DockIcon(.question, size: size, color: DockStatusTone.attention.color)
            case .decision: DockIcon(.sealCheck, size: size, color: Color.dockAccent)
            case .muted: DockIcon(.prohibit, size: size, color: Color.dockMetadataText)
            case nil: EmptyView()
            }
        }
    }

    /// Notes as rendered Markdown, with Mermaid fences drawn as diagrams.
    private static func segments(_ notes: String) -> [(isDiagram: Bool, text: String)] {
        var result: [(Bool, String)] = []
        var buffer: [Substring] = []
        var diagram: [Substring]?
        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append((false, text)) }
            buffer = []
        }
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = diagram {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    result.append((true, lines.joined(separator: "\n")))
                    diagram = nil
                } else {
                    lines.append(line)
                    diagram = lines
                }
            } else if trimmed.lowercased().hasPrefix("```mermaid") || trimmed.lowercased().hasPrefix("~~~mermaid") {
                flush()
                diagram = []
            } else {
                buffer.append(line)
            }
        }
        if let diagram { buffer += ["```mermaid"] + diagram }
        flush()
        return result
    }

    private func expanded(_ node: SpecMapNode) -> some View {
        let sources = sources(of: node)
        let notes = notes(of: node)
        let files = openFiles
        let noteIDs = overlay.notes[node.id] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            // Full height, no inner scroll: the Markdown view mounts only what its nearest
            // scroll view shows, so a nested one rendered blank until scrolled. The canvas scrolls.
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Self.segments(SpecMapParser.unwrapped(notes)).enumerated()), id: \.offset) {
                        _, segment in
                        if segment.isDiagram {
                            MermaidDiagramView(source: segment.text)
                        } else {
                            MarkdownMessageView(
                                markdown: segment.text, bodySize: DockTypography.size(.metadata))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(12)
                .dockWell(.sunken)
            }
            if !files.isEmpty {
                DockChipFlow(spacing: 6) {
                    ForEach(files, id: \.0) { path, url in
                        Button {
                            actions.openFile(url)
                        } label: {
                            DockIconLabel(url.lastPathComponent, icon: .fileText)
                        }
                        .buttonStyle(.dockLink)
                        .dockFont(.metadata)
                        .help("Open \(path)")
                    }
                }
            }
            if !sources.isEmpty || !node.unresolved.isEmpty {
                HStack(spacing: 6) {
                    Text(sources.contains { $0.status != .done } ? "Waiting on" : "Depends on")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                    ForEach(sources) { source in
                        Button {
                            select(source.id)
                        } label: {
                            HStack(spacing: 3) {
                                Text(source.label ?? Self.displayTitle(source.title)).underline()
                                DockIcon(.arrowUpRight, size: 9)
                            }
                            .dockFont(.compactStatus, weight: .medium)
                            .lineLimit(1)
                            .dockPill(tint: source.status == .done ? DockStatusTone.complete.color : Color.dockAccent)
                        }
                        .buttonStyle(.dockHover)
                        .dockPointerCursor()
                        .help(source.status == .done ? "\(source.title) is done. Go to it" : "Go to \(source.title)")
                    }
                    ForEach(node.unresolved, id: \.self) { reference in
                        Text(reference)
                            .dockFont(.compactStatus, weight: .medium)
                            .lineLimit(1)
                            .dockPill(tint: Color.dockWarning)
                            .help("Not found in this document")
                    }
                }
            }
            // Footer: where the step lives, quiet document actions, then the one primary action.
            HStack(spacing: 6) {
                Text("Line \(node.line)")
                    .dockFont(.machineMetadata)
                    .monospacedDigit()
                    .foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 8)
                // Outlined like Send to chat, so the footer reads as one row of actions.
                iconAction(
                    .fileText, "Show in document (Return)",
                    help: "Switch to Document and scroll to this step, highlighting its title in the plan text."
                ) { actions.reveal(node) }
                if let note = noteIDs.first {
                    Button {
                        actions.openNote(note)
                    } label: {
                        HStack(spacing: 5) {
                            DockIcon(.chatCircleText, size: 13)
                            Text("\(noteIDs.count)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.dockSecondary)
                    .fixedSize()
                    .help(
                        noteIDs.count == 1 ? "Open the note on this step" : "Open the first of \(noteIDs.count) notes")
                }
                iconAction(
                    .chatText, "Comment on this task",
                    help:
                        "Switch to Document and open a note on this step’s title. Notes collect as a review you send to Hermes."
                ) { actions.comment(node) }
                Button {
                    actions.send([node])
                } label: {
                    // 13pt to match the outlined icon actions beside it.
                    HStack(spacing: 5) {
                        DockIcon(.paperPlaneTilt, size: 13)
                        Text("Send to chat")
                    }
                }
                .buttonStyle(.dockPrimary)
                .fixedSize()
                .help(
                    "Add this step and its notes to the chat composer as a context chip, so you can ask Hermes to work on it. Nothing is sent until you send."
                )
                .dockPadding(.leading, 4)
            }
            .lineLimit(1)
            .dockButtonSize(.inline)
            .dockPadding(.top, 10)
            .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
        }
        .dockPadding(.horizontal, 12)
        .dockPadding(.bottom, 12)
        .transition(.opacity)
    }

    private func iconAction(_ icon: Ph, _ label: String, help: String, action: @escaping () -> Void) -> some View {
        DockIconAction(icon: icon, label: label, help: help, iconSize: 13, action: action)
    }

    // MARK: Wires

    /// Everything drawn behind the nodes, from frames read here in body: a read
    /// inside the Canvas closure is not tracked, so lines would miss layout updates.
    private var wires: some View {
        let (map, frames, collapsed, selectedID, showsRoot, isTree) =
            (map, frames, collapsed, selectedID, showsRoot, isTree)
        return SpecMapHoverReader(hover: hover) { hoveredID in
            Self.wireCanvas(
                SpecMapWires(
                    map: map, frames: frames, collapsed: collapsed, selectedID: selectedID, hoveredID: hoveredID,
                    showsRoot: showsRoot, isTree: isTree, gap: Metrics.branchGap, trunk: Metrics.trunk,
                    portDrop: Metrics.port))
        }
    }

    private static func wireCanvas(_ graph: SpecMapWires) -> some View {
        let loop = Metrics.loop
        let corner = Metrics.corner
        let socket = Metrics.socket
        return Canvas { context, _ in
            let line = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            let accent = Color.dockAccent

            // Pipeline: root → phase → phase.
            for (from, to) in graph.flow {
                let fromY = from.minY + min(from.height / 2, 34)
                let toY = to.minY + min(to.height / 2, 34)
                // Only the list chains phases; a tree reaches them through its root's branches.
                let (path, tip, tail) = Self.loop(
                    from: CGPoint(x: from.minX, y: fromY), to: CGPoint(x: to.minX - 3, y: toY), out: -loop)
                context.stroke(path, with: .color(accent.opacity(0.6)), style: line)
                context.fill(Self.arrowhead(at: tip, from: tail), with: .color(accent.opacity(0.6)))
            }

            // Trees: one quiet accent stroke, so overlapping trunks never darken.
            var tree = Path()
            for branch in graph.branches {
                tree.move(to: branch.start)
                if let bus = branch.bus {
                    tree.addLine(to: CGPoint(x: bus, y: branch.start.y))
                } else if let last = branch.ends.map(\.point.y).max() {
                    tree.addLine(to: CGPoint(x: branch.start.x, y: max(branch.start.y, last - corner)))
                }
                for end in branch.ends { tree.addPath(Self.twig(branch, to: end.point, corner: corner, gap: socket)) }
            }
            context.stroke(tree, with: .color(accent.opacity(0.35)), style: line)
            for branch in graph.branches {
                for end in branch.ends {
                    let isSelected = end.id == graph.selectedID
                    let color = isSelected ? accent : Self.wire(end.status)
                    if let color {
                        context.stroke(
                            Self.twig(branch, to: end.point, corner: corner, gap: socket),
                            with: .color(color),
                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, lineCap: .round))
                    }
                    // An input port seated on the card's edge, haloed so it reads as a joint, not a ring.
                    let halo = socket + 4
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: end.point.x - halo / 2, y: end.point.y - halo / 2, width: halo, height: halo)),
                        with: .color(Color.dockCanvas))
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: end.point.x - socket / 2, y: end.point.y - socket / 2, width: socket, height: socket)
                        ),
                        with: .color(color ?? accent.opacity(0.7)))
                }
            }

            // Dependencies: dashed, out of one side of the source and into the target.
            for dependency in graph.dependencies {
                let (path, tip, tail) = Self.route(dependency.source, to: dependency.target)
                let color = dependency.isHighlighted ? accent : accent.opacity(0.45)
                context.stroke(
                    path, with: .color(color),
                    style: StrokeStyle(
                        lineWidth: dependency.isHighlighted ? 2 : 1.25, lineCap: .round, dash: [5, 4]))
                context.fill(Self.arrowhead(at: tip, from: tail), with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Stated statuses get their tone; to-do and unstated steps stay on the quiet tree.
    private static func wire(_ status: SpecMapStatus?) -> Color? {
        switch status {
        case .done: DockStatusTone.complete.fill
        case .inProgress: DockStatusTone.working.fill
        case .blocked: DockStatusTone.attention.fill
        case .todo, nil: nil
        }
    }

    /// Trunk → rounded elbow → the child's left edge. A list's trunk drops from under the
    /// card; a tree's bus runs beside it, so a child can sit above the parent's line too.
    private static func twig(_ branch: SpecMapWires.Branch, to end: CGPoint, corner: CGFloat, gap: CGFloat) -> Path {
        var path = Path()
        guard let bus = branch.bus else {
            let x = branch.start.x
            path.move(to: CGPoint(x: x, y: end.y - corner))
            path.addQuadCurve(to: CGPoint(x: x + corner, y: end.y), control: CGPoint(x: x, y: end.y))
            path.addLine(to: CGPoint(x: end.x - gap / 2, y: end.y))
            return path
        }
        let dy = end.y - branch.start.y
        let radius = min(corner, abs(dy))
        path.move(to: CGPoint(x: bus, y: branch.start.y))
        if radius > 0.5 {
            let sign: CGFloat = dy > 0 ? 1 : -1
            path.addLine(to: CGPoint(x: bus, y: end.y - sign * radius))
            path.addQuadCurve(to: CGPoint(x: bus + radius, y: end.y), control: CGPoint(x: bus, y: end.y))
        }
        path.addLine(to: CGPoint(x: end.x - gap / 2, y: end.y))
        return path
    }

    /// A horizontal S-curve; `bend` is +1 rightward, −1 leftward. Returns the tip and its tangent's tail.
    private static func curve(from start: CGPoint, to end: CGPoint, bend: CGFloat) -> (Path, CGPoint, CGPoint) {
        let reach = max(36, abs(end.x - start.x) / 2)
        let c1 = CGPoint(x: start.x + bend * reach, y: start.y)
        let c2 = CGPoint(x: end.x - bend * reach, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        return (path, end, c2)
    }

    /// Forward wires leave the right edge, backward ones the left; within one column they loop out to the right.
    private static func route(_ source: CGRect, to target: CGRect) -> (Path, CGPoint, CGPoint) {
        let sourceY = source.minY + min(source.height / 2, 21)
        let targetY = target.minY + min(target.height / 2, 21)
        if target.minX > source.maxX {
            return curve(
                from: CGPoint(x: source.maxX, y: sourceY), to: CGPoint(x: target.minX - 3, y: targetY), bend: 1)
        }
        if target.maxX < source.minX {
            return curve(
                from: CGPoint(x: source.minX, y: sourceY), to: CGPoint(x: target.maxX + 3, y: targetY), bend: -1)
        }
        return loop(
            from: CGPoint(x: source.maxX, y: sourceY), to: CGPoint(x: target.maxX + 3, y: targetY),
            out: min(56, 18 + abs(targetY - sourceY) / 6))
    }

    /// Out of one side and back into the same side; negative `out` loops left.
    private static func loop(from start: CGPoint, to end: CGPoint, out: CGFloat) -> (Path, CGPoint, CGPoint) {
        let x = (out < 0 ? min(start.x, end.x) : max(start.x, end.x)) + out
        let c2 = CGPoint(x: x, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: x, y: start.y), control2: c2)
        return (path, end, c2)
    }

    private static func arrowhead(at tip: CGPoint, from tail: CGPoint) -> Path {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length: CGFloat = 7
        let spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: tip)
        path.addLine(
            to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        path.addLine(
            to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        path.closeSubpath()
        return path
    }
}

@Observable
private final class SpecMapHover {
    var id: String?
}

/// The only view that reads the hover, so a hover change re-runs just this body.
private struct SpecMapHoverReader<Content: View>: View {
    let hover: SpecMapHover
    @ViewBuilder let content: (String?) -> Content

    var body: some View { content(hover.id) }
}

/// What the canvas draws, resolved from measured frames against what is visible now.
private struct SpecMapWires {
    struct End {
        let id: String
        let point: CGPoint
        let status: SpecMapStatus?
    }

    struct Branch {
        let start: CGPoint
        /// A tree's vertical bus beside the parent; nil for a list's trunk under it.
        var bus: CGFloat?
        let ends: [End]
    }

    struct Dependency {
        let source: CGRect
        let target: CGRect
        let isHighlighted: Bool
    }

    let selectedID: String?
    let hoveredID: String?
    var flow: [(CGRect, CGRect)] = []
    var branches: [Branch] = []
    var dependencies: [Dependency] = []

    init(
        map: SpecMap, frames: [String: CGRect], collapsed: Set<String>, selectedID: String?, hoveredID: String?,
        showsRoot: Bool, isTree: Bool, gap: CGFloat,
        trunk: CGFloat, portDrop: CGFloat
    ) {
        self.selectedID = selectedID
        self.hoveredID = hoveredID
        let anchors = (showsRoot ? [frames["root"]] : []) + map.lanes.map { frames["phase:\($0.id)"] }
        let cards = anchors.compactMap(\.self)
        if !isTree, cards.count == anchors.count { flow = Array(zip(cards, cards.dropFirst())) }

        var visible = Set<String>()
        /// A tree wires into the header's middle; a list near the top of a tall card.
        func end(_ id: String, _ frame: CGRect, _ status: SpecMapStatus?) -> End {
            End(
                id: id, point: CGPoint(x: frame.minX, y: isTree ? frame.midY : frame.minY + min(frame.height / 2, 21)),
                status: status)
        }
        func branch(from card: CGRect?, lineY: CGFloat? = nil, to ends: [End]) {
            guard let card, !ends.isEmpty else { return }
            branches.append(
                isTree
                    ? Branch(start: CGPoint(x: card.maxX, y: lineY ?? card.midY), bus: card.maxX + gap / 2, ends: ends)
                    : Branch(start: CGPoint(x: card.minX + trunk, y: card.maxY + portDrop), ends: ends))
        }
        func steps(_ nodes: [SpecMapNode]) -> [End] {
            nodes.compactMap { node in frames["head:\(node.id)"].map { end(node.id, $0, node.status) } }
        }
        func walk(_ nodes: [SpecMapNode], in lane: SpecMapLane) {
            for node in nodes {
                visible.insert(node.id)
                let children = lane.children(of: node.id)
                guard !children.isEmpty, !collapsed.contains(node.id) else { continue }
                branch(from: frames["card:\(node.id)"], lineY: frames["head:\(node.id)"]?.midY, to: steps(children))
                walk(children, in: lane)
            }
        }
        if isTree, showsRoot {
            branch(
                from: frames["root"],
                to: map.lanes.compactMap { lane in frames["phase:\(lane.id)"].map { end(lane.id, $0, nil) } })
        }
        for lane in map.lanes where !collapsed.contains(lane.id) {
            branch(from: frames["phase:\(lane.id)"], to: steps(lane.nodes))
            walk(lane.nodes, in: lane)
        }

        for edge in map.edges where edge.kind == .dependency {
            guard visible.contains(edge.source), visible.contains(edge.target),
                let source = frames["head:\(edge.source)"], let target = frames["head:\(edge.target)"]
            else { continue }
            let lit = Set([selectedID, hoveredID].compactMap(\.self))
            let isHighlighted = lit.contains(edge.source) || lit.contains(edge.target)
            dependencies.append(Dependency(source: source, target: target, isHighlighted: isHighlighted))
        }
    }
}

private struct SpecMapTruncatedTip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

extension View {
    fileprivate func specFrame(_ key: String, _ store: @escaping (String, CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(SpecMapView.space))
        } action: {
            store(key, $0)
        }
    }
}

/// Phase completion as a ring around its `done/total` count.
private struct ProgressRing: View {
    let done: Int
    let total: Int
    let isActive: Bool

    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(Color.dockBorderStrong, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(DockStatusTone.complete.fill, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(done)/\(total)")
                .dockFont(.compactStatus, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(isActive ? Color.dockAccent : Color.dockSecondaryText)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}
