import AppKit
import Foundation
import SwiftUI

/// Stable identity for a transcript location. The session component prevents a
/// delayed viewport or selection update from targeting a similarly identified
/// message after the user changes sessions.
struct MessageNavigatorTarget: Hashable, Identifiable, Sendable {
    let sessionID: String
    let messageID: UUID

    var id: String { "\(sessionID):\(messageID.uuidString)" }
}

struct MessageNavigatorItem: Equatable, Identifiable, Sendable {
    let target: MessageNavigatorTarget
    let ordinal: Int
    let roleLabel: String
    let preview: String
    let contentRevision: Int
    let hasImages: Bool
    /// Text search matches: the full message body, not only the preview.
    var searchText: String = ""
    /// Set for a stored prompt that is not loaded into the transcript yet.
    /// Selecting it loads history through this row before jumping.
    var storedRowID: Int? = nil

    var id: MessageNavigatorTarget { target }
    var messageID: UUID { target.messageID }
    var sessionID: String { target.sessionID }
}

/// Immutable projection identity lets transcript refreshes skip walking unchanged history.
final class MessageNavigatorSnapshot: Sendable {
    let items: [MessageNavigatorItem]

    init(items: [MessageNavigatorItem]) {
        self.items = items
    }
}

enum MessageNavigator {
    static let defaultPreviewLimit = 160
    static let minimumPreviewLimit = 2
    static let minimumMessagesToShowNavigator = 24

    static func items(messages: [ChatMessage], sessionID: String, previewLimit: Int = defaultPreviewLimit)
        -> [MessageNavigatorItem]
    {
        let limit = max(minimumPreviewLimit, previewLimit)
        // Reuse previews when callers outside DockModel request the same projection.
        let fingerprint = projectionFingerprint(messages: messages, sessionID: sessionID, previewLimit: limit)
        if let memoized = memo.itemsIfFresh(fingerprint: fingerprint) {
            return memoized
        }
        let projected = messages.enumerated().map { index, message in
            let text = GenerativeUIIntegration.readableText(message)
            return MessageNavigatorItem(
                target: MessageNavigatorTarget(sessionID: sessionID, messageID: message.id),
                ordinal: index + 1,
                roleLabel: message.role == .user ? "You" : "Herm",
                preview: boundedPreview(text, limit: limit),
                contentRevision: message.contentRevision,
                hasImages: !message.images.isEmpty,
                searchText: text
            )
        }
        memo.store(items: projected, fingerprint: fingerprint)
        return projected
    }

    /// Loaded messages preceded by stored prompts that are older than the
    /// loaded transcript. Ordinals count positions in the combined list.
    static func items(
        messages: [ChatMessage],
        earlierPrompts: [TranscriptTimelineEntry],
        sessionID: String,
        previewLimit: Int = defaultPreviewLimit
    ) -> [MessageNavigatorItem] {
        let loaded = items(messages: messages, sessionID: sessionID, previewLimit: previewLimit)
        guard !earlierPrompts.isEmpty else { return loaded }
        let limit = max(minimumPreviewLimit, previewLimit)
        let prompts = earlierPrompts.enumerated().map { index, entry in
            MessageNavigatorItem(
                target: MessageNavigatorTarget(
                    sessionID: sessionID, messageID: placeholderMessageID(forRowID: entry.rowID)),
                ordinal: index + 1,
                roleLabel: "You",
                preview: boundedPreview(entry.preview, limit: limit),
                contentRevision: 0,
                hasImages: false,
                searchText: entry.preview,
                storedRowID: entry.rowID
            )
        }
        let offset = prompts.count
        return prompts
            + loaded.map { item in
                MessageNavigatorItem(
                    target: item.target,
                    ordinal: item.ordinal + offset,
                    roleLabel: item.roleLabel,
                    preview: item.preview,
                    contentRevision: item.contentRevision,
                    hasImages: item.hasImages,
                    searchText: item.searchText
                )
            }
    }

    /// Deterministic identity for a stored prompt that has no loaded message.
    static func placeholderMessageID(forRowID rowID: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-4000-8000-%012llx", UInt64(truncatingIfNeeded: rowID) & 0xFFFF_FFFF_FFFF))!
    }

    static func search(items: [MessageNavigatorItem], query: String) -> [MessageNavigatorItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return items }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var results: [MessageNavigatorItem] = []
        for item in items {
            guard !Task.isCancelled else { return [] }
            let body = item.searchText.isEmpty ? item.preview : item.searchText
            if body.range(of: normalizedQuery, options: options) != nil
                || item.roleLabel.range(of: normalizedQuery, options: options) != nil
            {
                results.append(item)
            }
        }
        return results
    }

    static func searchInBackground(items: [MessageNavigatorItem], query: String) async throws -> [MessageNavigatorItem]
    {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            assert(!Thread.isMainThread)
            return search(items: items, query: query)
        }
        return try await withTaskCancellationHandler {
            let results = await worker.value
            try Task.checkCancellation()
            return results
        } onCancel: {
            worker.cancel()
        }
    }

    /// Single-entry memo for the last projection. Lock-guarded rather than
    /// `@MainActor` because tests and SwiftUI both call `items` synchronously
    /// from different isolation domains.
    private static let memo = ItemMemo()

    private final class ItemMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var fingerprint: UInt64 = 0
        private var cachedItems: [MessageNavigatorItem] = []

        func itemsIfFresh(fingerprint: UInt64) -> [MessageNavigatorItem]? {
            lock.lock()
            defer { lock.unlock() }
            guard fingerprint == self.fingerprint else { return nil }
            return cachedItems
        }

        func store(items: [MessageNavigatorItem], fingerprint: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            self.fingerprint = fingerprint
            self.cachedItems = items
        }
    }

    /// FNV-1a over the projection inputs: O(messages) with no string
    /// formatting or body scanning. `ChatMessage.contentRevision` already
    /// stands in for the full Markdown body in row-equality checks, so it is
    /// an equally safe fingerprint component here.
    private static func projectionFingerprint(
        messages: [ChatMessage], sessionID: String, previewLimit: Int
    ) -> UInt64 {
        var value: UInt64 = 1_469_598_103_934_665_603
        func mix(_ byte: UInt8) {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        func mix(_ integer: UInt64) {
            withUnsafeBytes(of: integer.littleEndian) { $0.forEach(mix) }
        }
        sessionID.utf8.forEach(mix)
        mix(UInt64(previewLimit))
        mix(UInt64(messages.count))
        for message in messages {
            withUnsafeBytes(of: message.id) { $0.forEach(mix) }
            mix(UInt64(bitPattern: Int64(message.contentRevision)))
            mix(message.role == .user ? UInt64(1) : 0)
            mix(UInt64(message.images.count))
        }
        return value
    }

    static func target(
        for messageID: UUID, sessionID: String, visibleIn visibleTargets: [MessageNavigatorTarget]? = nil
    ) -> MessageNavigatorTarget? {
        let target = MessageNavigatorTarget(sessionID: sessionID, messageID: messageID)
        guard let visibleTargets else { return target }
        return visibleTargets.contains(target) ? target : nil
    }

    static func nearestVisibleTarget(
        to requestedTarget: MessageNavigatorTarget, visibleTargets: [MessageNavigatorTarget]
    ) -> MessageNavigatorTarget? {
        guard visibleTargets.contains(requestedTarget) else { return nil }
        return requestedTarget
    }

    static func boundedPreview(_ text: String, limit: Int = defaultPreviewLimit) -> String {
        let safeLimit = max(minimumPreviewLimit, limit)
        // Previews stop at `safeLimit` normalized characters, so normalizing
        // the full transcript-sized body is wasted work that scales with
        // total message bytes on every projection rebuild. Normalizing a
        // bounded head reaches the same truncation verdict whenever it holds
        // enough content; only whitespace-dominated openings that exhaust the
        // head fall back to the full body, keeping the output identical to
        // an unbounded normalization.
        let head = text.prefix(previewHeadScanLimit(for: safeLimit))
        let normalizedHead = normalizePreviewWhitespace(head)
        if normalizedHead.count > safeLimit {
            return String(normalizedHead.prefix(safeLimit - 1)) + "…"
        }
        guard head.endIndex != text.endIndex else { return normalizedHead }
        let normalized = normalizePreviewWhitespace(text)
        guard normalized.count > safeLimit else { return normalized }
        return String(normalized.prefix(safeLimit - 1)) + "…"
    }

    private static func normalizePreviewWhitespace<S: StringProtocol>(_ text: S) -> String {
        String(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func previewHeadScanLimit(for safeLimit: Int) -> Int {
        safeLimit * 8 + 64
    }
}

struct MessageNavigatorViewport: Equatable {
    let target: MessageNavigatorTarget
    let index: Int
    let minY: CGFloat
    let maxY: CGFloat
}

struct MessageNavigatorViewportPreferenceKey: PreferenceKey {
    static let defaultValue: [MessageNavigatorViewport] = []

    static func reduce(value: inout [MessageNavigatorViewport], nextValue: () -> [MessageNavigatorViewport]) {
        value.append(contentsOf: nextValue())
    }
}

struct MessageNavigatorView: View {
    let snapshot: MessageNavigatorSnapshot
    private var items: [MessageNavigatorItem] { snapshot.items }
    let sessionID: String
    let visibleTargets: Set<MessageNavigatorTarget>
    /// The find panel stays hidden until the header search action opens it.
    @Binding var isSearchPresented: Bool
    /// The marker rail needs room beside the transcript; search does not.
    var showsMap = true
    /// Older stored history is being read so search covers all of it.
    var isLoadingHistory = false
    /// Called when a non-empty search starts, so older history can load.
    var onSearch: () -> Void = {}
    let onSelect: (MessageNavigatorItem) -> Void

    @State private var selectedTarget: MessageNavigatorTarget?
    @State private var hoveredTarget: MessageNavigatorTarget?
    @State private var clearHoverTask: Task<Void, Never>?
    @State private var searchQuery = ""
    @State private var hoveredResult: MessageNavigatorTarget?
    /// Full-text matching scans every message body, so results are computed
    /// when the query or items change instead of on every hover render.
    @State private var searchState = MessageNavigatorSearchState()
    @FocusState private var isSearchFocused: Bool

    private var hasSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchInput: MessageNavigatorSearchRequest? {
        guard isSearchPresented, hasSearchQuery else { return nil }
        return .init(snapshot: snapshot, sessionID: sessionID, query: searchQuery)
    }

    private var activeTarget: MessageNavigatorTarget? {
        hoveredTarget ?? selectedTarget ?? currentVisibleItem?.target
    }

    private var currentVisibleItem: MessageNavigatorItem? {
        let visibleItems = items.filter { visibleTargets.contains($0.target) }
        guard !visibleItems.isEmpty else { return nil }
        return visibleItems[visibleItems.count / 2]
    }

    static func dispatchSelection(
        _ item: MessageNavigatorItem,
        onSelect: @escaping (MessageNavigatorItem) -> Void
    ) {
        onSelect(item)
    }

    static func nextSelectionIndex(
        direction: MoveCommandDirection,
        currentIndex: Int?,
        count: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        let index = currentIndex ?? 0
        switch direction {
        case .up:
            return max(0, index - 1)
        case .down:
            return currentIndex == nil ? 0 : min(count - 1, index + 1)
        default:
            return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if !items.isEmpty {
                    if showsMap {
                        messageMap(in: CGSize(width: 286, height: geometry.size.height))
                            .frame(width: 286, height: geometry.size.height)
                    }
                    if isSearchPresented {
                        searchPanel
                            .frame(width: 300, alignment: .leading)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.dockEase(duration: 0.16), value: isSearchPresented)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: sessionID) { _, _ in
            clearHoverTask?.cancel()
            selectedTarget = nil
            hoveredTarget = nil
            searchQuery = ""
            isSearchPresented = false
        }
        .onChange(of: isSearchPresented) { _, presented in
            if !presented { searchQuery = "" }
        }
        .onDisappear {
            clearHoverTask?.cancel()
            hoveredTarget = nil
        }
        .onChange(of: searchQuery) { _, _ in
            if hasSearchQuery { onSearch() }
        }
        .onChange(of: searchInput) { _, input in searchState.invalidateSelection(for: input) }
        .task(id: searchInput) {
            guard let input = searchInput else {
                searchState = MessageNavigatorSearchState()
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let results = try await MessageNavigator.searchInBackground(
                    items: input.snapshot.items, query: input.query)
                try Task.checkCancellation()
                if let item = searchState.complete(results, for: input, current: searchInput) {
                    selectSearchResult(item)
                }
            } catch is CancellationError {
                // A new query, history revision, close, or session change owns the next result.
            } catch {
                assertionFailure("Unexpected search failure: \(error)")
            }
        }
        .onMoveCommand { direction in
            guard hoveredTarget != nil, !items.isEmpty else { return }
            let currentIndex = items.firstIndex { $0.target == selectedTarget }
            guard
                let nextIndex = Self.nextSelectionIndex(
                    direction: direction,
                    currentIndex: currentIndex,
                    count: items.count
                )
            else { return }
            let item = items[nextIndex]
            selectedTarget = item.target
            Self.dispatchSelection(item, onSelect: onSelect)
        }
    }

    private var searchPanel: some View {
        let searchResults = searchState.results(for: searchInput)
        let isSearching = hasSearchQuery && !searchState.isComplete(for: searchInput)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 13, color: Color.dockMetadataText)
                DockTextField("Find a message", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .dockFont(.navigation)
                    .foregroundStyle(Color.dockPrimaryText)
                    .focused($isSearchFocused)
                    .onSubmit(selectFirstSearchResult)
                    .onExitCommand { isSearchPresented = false }
                    .accessibilityLabel("Find a message")
                if hasSearchQuery, !searchResults.isEmpty {
                    Text("\(searchResults.count)")
                        .dockFont(.metadata, weight: .medium).monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                }
                Button {
                    isSearchPresented = false
                } label: {
                    DockIcon(.x, size: 11, color: Color.dockSecondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help("Close search (Esc)")
                .accessibilityLabel("Close search")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 38)

            if hasSearchQuery {
                Color.dockBorder.frame(height: DockLayout.hairline)
                if searchResults.isEmpty {
                    Text(
                        isLoadingHistory
                            ? "Searching earlier messages…"
                            : isSearching ? "Searching messages…" : "No matching messages"
                    )
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(searchResults) { item in
                                Button {
                                    selectedTarget = item.target
                                    Self.dispatchSelection(item, onSelect: onSelect)
                                    isSearchPresented = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(item.roleLabel)
                                                .dockFont(.metadata, weight: .semibold)
                                                .foregroundStyle(
                                                    item.roleLabel == "You" ? Color.dockAccent : Color.dockPrimaryText)
                                            Text("#\(item.ordinal)")
                                                .dockFont(.compactStatus, weight: .regular).monospacedDigit()
                                                .foregroundStyle(Color.dockMetadataText)
                                        }
                                        Text(item.preview.isEmpty ? "(empty message)" : item.preview)
                                            .dockFont(.body)
                                            .foregroundStyle(Color.dockSecondaryText)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        item.target == hoveredResult ? Color.dockSurface4 : Color.clear,
                                        in: RoundedRectangle(
                                            cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                                    .onHover {
                                        hoveredResult =
                                            $0 ? item.target : (hoveredResult == item.target ? nil : hoveredResult)
                                    }
                                }
                                .buttonStyle(.dockHover)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
        .dockFloatingSurface(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous), lineWidth: 0.5)
        .shadow(color: .black.opacity(DockThemeStyle.current.material == .glass ? 0 : 0.22), radius: 14, y: 6)
        .onAppear { isSearchFocused = true }
    }

    private func selectFirstSearchResult() {
        guard let input = searchInput, let item = searchState.submit(input) else { return }
        selectSearchResult(item)
    }

    private func selectSearchResult(_ item: MessageNavigatorItem) {
        selectedTarget = item.target
        Self.dispatchSelection(item, onSelect: onSelect)
        isSearchPresented = false
    }

    private func messageMap(in size: CGSize) -> some View {
        let markers = mapItems
        let activeTarget = self.activeTarget
        let activeIndex = markers.firstIndex { $0.target == hoveredTarget }
        let previewItem = items.first { $0.target == hoveredTarget }
        let previewY =
            previewItem.flatMap { item in
                markers.firstIndex(where: { $0.target == item.target }).map {
                    markerY(at: $0, count: markers.count, in: size.height)
                }
            } ?? size.height / 2
        let hoverZoneHeight =
            markers.count > 1
            ? markerTrackHeight(in: size.height) / CGFloat(markers.count - 1) + 2
            : 12

        // Nearest marker for a y inside the strip below.
        func markerIndex(atY y: CGFloat) -> Int? {
            guard !markers.isEmpty else { return nil }
            let trackHeight = markerTrackHeight(in: size.height)
            let fraction = trackHeight > 0 ? (y - 12 - hoverZoneHeight / 2) / trackHeight : 0
            return min(max(0, Int((fraction * CGFloat(markers.count - 1)).rounded())), markers.count - 1)
        }

        return ZStack(alignment: .topLeading) {
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, item in
                let distanceFromHover = activeIndex.map { abs(index - $0) }
                let isHovered = item.target == hoveredTarget
                let width = markerWidth(for: item, isHovered: isHovered, distanceFromHover: distanceFromHover)
                // Plain drawings: a Button or .help here installs AppKit views
                // that swallow the pointer over the resting bars. The strip
                // below owns hover and clicks for the whole rail.
                Capsule()
                    .fill(markerColor(for: item, activeTarget: activeTarget, distanceFromHover: distanceFromHover))
                    .frame(width: width, height: 3)
                    .frame(width: 28, height: hoverZoneHeight, alignment: .leading)
                    .animation(
                        .easeInOut(duration: 0.16).delay(Double(distanceFromHover ?? 5) * 0.022),
                        value: hoveredTarget
                    )
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Jump to message \(item.ordinal), \(item.roleLabel)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        selectedTarget = item.target
                        Self.dispatchSelection(item, onSelect: onSelect)
                    }
                    // The marker frame must sit inside the rail's bounds:
                    // SwiftUI drops hover for anything drawn outside its parent.
                    .position(x: 14, y: markerY(at: index, count: markers.count, in: size.height))
            }

            // One strip on top of the markers: the wave follows the pointer's y.
            RailPointerStrip(
                onMove: { y in
                    guard let index = markerIndex(atY: y) else { return }
                    clearHoverTask?.cancel()
                    if hoveredTarget != markers[index].target { hoveredTarget = markers[index].target }
                },
                onExit: { if let leaving = hoveredTarget { scheduleHoverClear(for: leaving) } },
                onClick: { y in
                    guard let index = markerIndex(atY: y) else { return }
                    selectedTarget = markers[index].target
                    Self.dispatchSelection(markers[index], onSelect: onSelect)
                }
            )
            // The whole rail block, not just the bars: SwiftUI's hit area for
            // the bars sat left of their drawing, so cover a wide band too.
            .frame(width: 120, height: markerTrackHeight(in: size.height) + hoverZoneHeight + 24)
            .position(x: 60, y: size.height / 2)

            if let previewItem {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(previewItem.ordinal) · \(previewItem.roleLabel)")
                        .dockFont(.compactStatus, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(previewItem.preview.isEmpty ? "(empty message)" : previewItem.preview)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(width: 160, alignment: .leading)
                .dockFloatingSurface(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous), lineWidth: 0.5
                )
                .shadow(color: .black.opacity(DockThemeStyle.current.material == .glass ? 0 : 0.18), radius: 8, y: 3)
                .position(x: 107, y: min(max(previewY, 52), max(52, size.height - 40)))
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.dockEase(duration: 0.16), value: hoveredTarget)
        .animation(.dockEase(duration: 0.16), value: selectedTarget)
    }

    private var mapItems: [MessageNavigatorItem] {
        let markerCount = 24
        guard items.count > markerCount else { return items }
        return (0..<markerCount).map { marker in
            let index = Int((Double(marker) / Double(markerCount - 1) * Double(items.count - 1)).rounded())
            return items[index]
        }
    }

    private func markerY(at index: Int, count: Int, in height: CGFloat) -> CGFloat {
        let trackHeight = markerTrackHeight(in: height)
        let top = (height - trackHeight) / 2
        guard count > 1 else { return height / 2 }
        return top + CGFloat(index) / CGFloat(count - 1) * trackHeight
    }

    private func markerTrackHeight(in height: CGFloat) -> CGFloat {
        min(max(0, height - 24), height * 0.30)
    }

    private func scheduleHoverClear(for leavingTarget: MessageNavigatorTarget) {
        clearHoverTask?.cancel()
        clearHoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, hoveredTarget == leavingTarget else { return }
            hoveredTarget = nil
        }
    }

    private func markerWidth(for item: MessageNavigatorItem, isHovered: Bool, distanceFromHover: Int?) -> CGFloat {
        guard let distanceFromHover else { return visibleTargets.contains(item.target) ? 10 : 6 }
        return switch distanceFromHover {
        case 0: 26
        case 1: 21
        case 2: 16
        case 3: 12
        case 4: 9
        default: isHovered ? 26 : 6
        }
    }

    private func markerColor(
        for item: MessageNavigatorItem, activeTarget: MessageNavigatorTarget?, distanceFromHover: Int?
    ) -> Color {
        if item.target == activeTarget { return Color.dockAccent }
        if let distanceFromHover, distanceFromHover <= 3 {
            return Color.dockAccent.opacity(0.72 - Double(distanceFromHover) * 0.16)
        }
        if visibleTargets.contains(item.target) { return Color.dockPrimaryText.opacity(0.9) }
        return Color.dockMetadataText.opacity(0.62)
    }

}

/// AppKit tracking area for the marker rail. SwiftUI hover and tap regions
/// here drifted left of the drawn bars; an NSView's tracking area follows the
/// view's real frame. Reports the pointer's y in the strip's top-left space.
private struct RailPointerStrip: NSViewRepresentable {
    var onMove: (CGFloat) -> Void
    var onExit: () -> Void
    var onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> StripView { StripView() }

    func updateNSView(_ view: StripView, context: Context) {
        view.onMove = onMove
        view.onExit = onExit
        view.onClick = onClick
    }

    /// Polls the pointer instead of relying on hover events: something over the
    /// right edge of the chat swallows them before SwiftUI or this view's
    /// tracking area sees them, so the pointer is hit-tested against the
    /// strip's on-screen frame directly.
    final class StripView: NSView {
        var onMove: (CGFloat) -> Void = { _ in }
        var onExit: () -> Void = {}
        var onClick: (CGFloat) -> Void = { _ in }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var timer: Timer?
        private var clickMonitor: Any?
        private var isInside = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            timer = nil
            clickMonitor = nil
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if let self, let y = self.pointerY(), event.window === self.window { self.onClick(y) }
                return event
            }
        }

        isolated deinit {
            timer?.invalidate()
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }

        /// The pointer's y in this view, or nil when it is outside the strip.
        private func pointerY() -> CGFloat? {
            guard let window, window.isVisible else { return nil }
            let pointer = NSEvent.mouseLocation
            let inWindow = window.convertPoint(fromScreen: pointer)
            let local = convert(inWindow, from: nil)
            // Most timer ticks are outside the rail; avoid a WindowServer query there.
            guard bounds.contains(local),
                NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return nil }
            return local.y
        }

        private func poll() {
            if let y = pointerY() {
                isInside = true
                onMove(y)
            } else if isInside {
                isInside = false
                onExit()
            }
        }
    }
}
