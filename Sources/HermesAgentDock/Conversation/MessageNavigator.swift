import Foundation
import SwiftUI

/// Stable identity for a transcript location. The session component prevents a
/// delayed viewport or selection update from targeting a similarly identified
/// message after the user changes sessions.
struct MessageNavigatorTarget: Hashable, Identifiable {
    let sessionID: String
    let messageID: UUID

    var id: String { "\(sessionID):\(messageID.uuidString)" }
}

struct MessageNavigatorItem: Equatable, Identifiable {
    let target: MessageNavigatorTarget
    let ordinal: Int
    let roleLabel: String
    let preview: String
    let contentRevision: Int
    let hasImages: Bool

    var id: MessageNavigatorTarget { target }
    var messageID: UUID { target.messageID }
    var sessionID: String { target.sessionID }
}

enum MessageNavigator {
    static let defaultPreviewLimit = 160
    static let minimumPreviewLimit = 2
    static let minimumMessagesToShowNavigator = 24

    static func items(messages: [ChatMessage], sessionID: String, previewLimit: Int = defaultPreviewLimit) -> [MessageNavigatorItem] {
        let limit = max(minimumPreviewLimit, previewLimit)
        // The transcript rebuilds this projection inside its body, which the
        // popover re-evaluates on every scroll frame and model publication.
        // Serve the unchanged projection from the memo instead of
        // re-normalizing a preview for every message in the session.
        let fingerprint = projectionFingerprint(messages: messages, sessionID: sessionID, previewLimit: limit)
        if let memoized = memo.itemsIfFresh(fingerprint: fingerprint) {
            return memoized
        }
        let projected = messages.enumerated().map { index, message in
            MessageNavigatorItem(
                target: MessageNavigatorTarget(sessionID: sessionID, messageID: message.id),
                ordinal: index + 1,
                roleLabel: message.role == .user ? "You" : "Hermes",
                preview: boundedPreview(message.text, limit: limit),
                contentRevision: message.contentRevision,
                hasImages: !message.images.isEmpty
            )
        }
        memo.store(items: projected, fingerprint: fingerprint)
        return projected
    }

    static func search(items: [MessageNavigatorItem], query: String) -> [MessageNavigatorItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return items }
        let foldedQuery = normalizedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return items.filter { item in
            item.preview.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(foldedQuery)
                || item.roleLabel.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(foldedQuery)
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

    static func target(for messageID: UUID, sessionID: String, visibleIn visibleTargets: [MessageNavigatorTarget]? = nil) -> MessageNavigatorTarget? {
        let target = MessageNavigatorTarget(sessionID: sessionID, messageID: messageID)
        guard let visibleTargets else { return target }
        return visibleTargets.contains(target) ? target : nil
    }

    static func nearestVisibleTarget(to requestedTarget: MessageNavigatorTarget, visibleTargets: [MessageNavigatorTarget]) -> MessageNavigatorTarget? {
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
    let items: [MessageNavigatorItem]
    let sessionID: String
    let visibleTargets: Set<MessageNavigatorTarget>
    let onSelect: (MessageNavigatorItem) -> Void

    @State private var selectedTarget: MessageNavigatorTarget?
    @State private var hoveredTarget: MessageNavigatorTarget?
    @State private var clearHoverTask: Task<Void, Never>?
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool

    private var searchResults: [MessageNavigatorItem] {
        MessageNavigator.search(items: items, query: searchQuery)
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
            ZStack(alignment: .topTrailing) {
                if !items.isEmpty {
                    messageMap(in: CGSize(width: 286, height: geometry.size.height))
                        .frame(width: 286, height: geometry.size.height)
                    searchPanel
                        .frame(width: 270, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: sessionID) { _, _ in
            clearHoverTask?.cancel()
            selectedTarget = nil
            hoveredTarget = nil
            searchQuery = ""
        }
        .onDisappear {
            clearHoverTask?.cancel()
            hoveredTarget = nil
        }
        .onMoveCommand { direction in
            guard hoveredTarget != nil, !items.isEmpty else { return }
            let currentIndex = items.firstIndex { $0.target == selectedTarget }
            guard let nextIndex = Self.nextSelectionIndex(
                direction: direction,
                currentIndex: currentIndex,
                count: items.count
            ) else { return }
            let item = items[nextIndex]
            selectedTarget = item.target
            Self.dispatchSelection(item, onSelect: onSelect)
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Find a message", text: $searchQuery)
                .textFieldStyle(.dockGlass)
                .focused($isSearchFocused)
                .onSubmit(selectFirstSearchResult)
                .accessibilityLabel("Find a message")

            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if searchResults.isEmpty {
                    Text("No matching messages")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .padding(7)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(searchResults) { item in
                                Button {
                                    selectedTarget = item.target
                                    Self.dispatchSelection(item, onSelect: onSelect)
                                    isSearchFocused = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(item.ordinal) · \(item.roleLabel)")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(item.preview.isEmpty ? "(empty message)" : item.preview)
                                            .font(.system(size: 11))
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(item.target == selectedTarget ? Color.dockAccent.opacity(0.18) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.dockBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private func selectFirstSearchResult() {
        guard let item = searchResults.first else { return }
        selectedTarget = item.target
        Self.dispatchSelection(item, onSelect: onSelect)
        isSearchFocused = false
    }

    private func messageMap(in size: CGSize) -> some View {
        let markers = mapItems
        let activeTarget = self.activeTarget
        let activeIndex = markers.firstIndex { $0.target == hoveredTarget }
        let previewItem = items.first { $0.target == hoveredTarget }
        let previewY = previewItem.flatMap { item in
            markers.firstIndex(where: { $0.target == item.target }).map { markerY(at: $0, count: markers.count, in: size.height) }
        } ?? size.height / 2
        let hoverZoneHeight = markers.count > 1
            ? markerTrackHeight(in: size.height) / CGFloat(markers.count - 1) + 2
            : 12

        return ZStack(alignment: .topLeading) {
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, item in
                let distanceFromHover = activeIndex.map { abs(index - $0) }
                let isHovered = item.target == hoveredTarget
                let width = markerWidth(for: item, isHovered: isHovered, distanceFromHover: distanceFromHover)
                Button {
                    selectedTarget = item.target
                    Self.dispatchSelection(item, onSelect: onSelect)
                } label: {
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(Color.clear)
                            .frame(width: width, height: hoverZoneHeight)
                            .contentShape(Rectangle())
                            .onHover { isHovering in
                                if isHovering {
                                    clearHoverTask?.cancel()
                                    hoveredTarget = item.target
                                } else {
                                    scheduleHoverClear(for: item.target)
                                }
                            }
                        Capsule()
                            .fill(markerColor(for: item, activeTarget: activeTarget, distanceFromHover: distanceFromHover))
                            .frame(width: width, height: 3)
                            .allowsHitTesting(false)
                    }
                    .frame(width: 28, height: hoverZoneHeight, alignment: .trailing)
                    .contentShape(Rectangle())
                    .animation(
                        .easeInOut(duration: 0.16).delay(Double(distanceFromHover ?? 5) * 0.022),
                        value: hoveredTarget
                    )
                }
                .buttonStyle(.plain)
                .position(x: size.width - 7, y: markerY(at: index, count: markers.count, in: size.height))
                .help("\(item.ordinal) · \(item.roleLabel): \(item.preview)")
                .accessibilityLabel("Jump to message \(item.ordinal), \(item.roleLabel)")
            }

            if let previewItem {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(previewItem.ordinal) · \(previewItem.roleLabel)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(previewItem.preview.isEmpty ? "(empty message)" : previewItem.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(width: 160, alignment: .leading)
                .background(Color.dockSurface4, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .position(x: size.width - 100, y: min(max(previewY, 52), max(52, size.height - 40)))
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

    private func markerColor(for item: MessageNavigatorItem, activeTarget: MessageNavigatorTarget?, distanceFromHover: Int?) -> Color {
        if item.target == activeTarget { return Color.dockAccent }
        if let distanceFromHover, distanceFromHover <= 3 {
            return Color.dockAccent.opacity(0.72 - Double(distanceFromHover) * 0.16)
        }
        if visibleTargets.contains(item.target) { return Color.dockPrimaryText.opacity(0.9) }
        return Color.dockMetadataText.opacity(0.62)
    }

}
