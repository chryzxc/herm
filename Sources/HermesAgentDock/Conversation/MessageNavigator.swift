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

    @State private var isExpanded = false
    @State private var query = ""
    @State private var selectedTarget: MessageNavigatorTarget?
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [MessageNavigatorItem] {
        MessageNavigator.search(items: items, query: query)
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
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                isExpanded.toggle()
                if isExpanded { isSearchFocused = true }
            } label: {
                Label("Messages", systemImage: "list.number")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Navigate messages")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Find a message", text: $query)
                        .textFieldStyle(.dockGlass)
                        .focused($isSearchFocused)
                        .onSubmit(selectFirstMatch)

                    if filteredItems.isEmpty {
                        Text("No matching messages")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(filteredItems) { item in
                                        Button {
                                            selectedTarget = item.target
                                            Self.dispatchSelection(item, onSelect: onSelect)
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
                                            .background(rowColor(for: item))
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }
                                        .buttonStyle(.plain)
                                        .id(item.id)
                                    }
                                }
                            }
                            .frame(width: 250, height: 240)
                            .onChange(of: selectedTarget) { _, target in
                                guard let target else { return }
                                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) }
                            }
                        }
                    }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
            }
        }
        .onChange(of: sessionID) { _, _ in
            selectedTarget = nil
            query = ""
        }
        .onMoveCommand { direction in
            guard isExpanded, !filteredItems.isEmpty else { return }
            let currentIndex = filteredItems.firstIndex { $0.target == selectedTarget }
            guard let nextIndex = Self.nextSelectionIndex(
                direction: direction,
                currentIndex: currentIndex,
                count: filteredItems.count
            ) else { return }
            let item = filteredItems[nextIndex]
            selectedTarget = item.target
            Self.dispatchSelection(item, onSelect: onSelect)
        }
    }

    private func rowColor(for item: MessageNavigatorItem) -> Color {
        if item.target == selectedTarget { return Color.accentColor.opacity(0.24) }
        if visibleTargets.contains(item.target) { return Color.primary.opacity(0.08) }
        return .clear
    }

    private func selectFirstMatch() {
        guard let item = filteredItems.first else { return }
        selectedTarget = item.target
        Self.dispatchSelection(item, onSelect: onSelect)
    }
}
