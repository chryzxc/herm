import Combine
import Foundation
import SwiftUI

enum ResponseDurationFormatting {
    static func string(seconds: TimeInterval) -> String {
        let rounded = max(0, seconds)
        if rounded < 60 {
            return String(format: "%.1fs", rounded)
        }
        let totalSeconds = Int(rounded)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, remainingSeconds)
        }
        return String(format: "%dm %02ds", minutes, remainingSeconds)
    }
}

struct ResponseDurationLabel: View {
    let startedAt: Date
    let finishedDuration: TimeInterval?

    var body: some View {
        if let finishedDuration {
            label(for: finishedDuration)
        } else {
            TimelineView(.dockMotion(rate: 2)) { context in
                label(for: context.date.timeIntervalSince(startedAt))
            }
        }
    }

    private func label(for seconds: TimeInterval) -> some View {
        HStack(spacing: 4) {
            DockIcon(.timer, size: 12, color: .dockMetadataText)
            Text(ResponseDurationFormatting.string(seconds: seconds))
        }
    }
}

struct StreamingPresentationChunk: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let revision: Int
    let isMutableTail: Bool
    let context: StreamingChunkContext

    nonisolated static func == (
        lhs: StreamingPresentationChunk,
        rhs: StreamingPresentationChunk
    ) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }
}

indirect enum StreamingChunkContext: Equatable, Sendable {
    case markdown
    case paragraph
    case list(marker: String, indentation: Int)
    case quote(depth: Int)
    case table
    case inline(delimiter: String, base: StreamingChunkContext)
    case fencedCode(marker: Character, length: Int, language: String?)
}

enum StreamingChunkPolicy {
    static let targetStableChunkBytes = 4_096
    static let maxMutableTailBytes = 8_192

    static func promotionBoundary(in tail: String) -> String.Index? {
        guard tail.utf8.count > maxMutableTailBytes else { return nil }
        return promotionBoundary(in: tail[...], bytes: tail.utf8.count, context: .markdown)
    }

    private static func promotionBoundary(
        in tail: Substring, bytes: Int, context: StreamingChunkContext
    ) -> String.Index {
        var fence: MarkdownFence?
        if case .fencedCode(let marker, let length, let language) = context {
            fence = MarkdownFence(marker: marker, length: length, language: language)
        }
        let target = min(maxMutableTailBytes, max(targetStableChunkBytes, bytes / 2))
        var lineStart = tail.startIndex
        var cursor = lineStart
        var fallback = cursor
        var scanned = 0
        // Search only a chunk-sized window. A restored one-line reply may be megabytes long.
        while cursor < tail.endIndex, scanned < maxMutableTailBytes {
            let character = tail[cursor]
            let next = tail.index(after: cursor)
            scanned += tail[cursor..<next].utf8.count
            if scanned > maxMutableTailBytes, fallback != tail.startIndex { break }
            if scanned <= target || fallback == tail.startIndex { fallback = next }
            if character == "\n" {
                let line = String(tail[lineStart..<cursor])
                if let active = fence {
                    if active.isClosed(by: line) { fence = nil }
                    if scanned >= targetStableChunkBytes { return next }
                } else if let opening = MarkdownFence(opening: line) {
                    fence = opening
                } else if scanned >= targetStableChunkBytes, line.trimmingCharacters(in: .whitespaces).isEmpty,
                    !inlineBoundaries(in: tail[..<next]).isUnclosed
                {
                    return next
                }
                lineStart = next
            }
            cursor = next
        }
        if fence != nil { return fallback }
        return inlineBoundaries(in: tail[..<fallback]).lastSafeWhitespace ?? fallback
    }

    struct Promotion: Sendable {
        struct Segment: Sendable {
            let text: String
            let context: StreamingChunkContext
        }
        let stable: [Segment]
        let tail: String
        let context: StreamingChunkContext
    }

    static func prepare(_ input: String, startingIn initial: StreamingChunkContext) -> Promotion {
        var remaining = input[...]
        var bytes = remaining.utf8.count
        var context = initial
        var segments: [Promotion.Segment] = []
        while bytes > maxMutableTailBytes, !Task.isCancelled {
            let boundary = promotionBoundary(in: remaining, bytes: bytes, context: context)
            let stable = remaining[..<boundary]
            let text = String(stable)
            segments.append(.init(text: text, context: context))
            context = contextAfter(text, startingIn: context)
            bytes -= stable.utf8.count
            remaining = remaining[boundary...]
        }
        return Promotion(stable: segments, tail: String(remaining), context: context)
    }

    /// A promoted section is parsed independently. Do not cut through the
    /// common inline constructs whose delimiter may be completed in a later
    /// delta; keeping the construct in the mutable tail preserves its rich
    /// presentation without reparsing stable text.
    private static func inlineBoundaries(in source: Substring) -> (isUnclosed: Bool, lastSafeWhitespace: String.Index?)
    {
        var codeDelimiter: Int?
        var bracketDepth = 0
        var parenthesisDepth = 0
        var emphasisDepth = 0
        var index = source.startIndex
        var escaped = false
        var lastSafeWhitespace: String.Index?
        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace, codeDelimiter == nil, bracketDepth == 0,
                parenthesisDepth == 0, emphasisDepth == 0
            {
                lastSafeWhitespace = source.index(after: index)
            }
            if escaped {
                escaped = false
                index = source.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = source.index(after: index)
                continue
            }
            if character == "`" {
                var end = index
                while end < source.endIndex, source[end] == "`" { end = source.index(after: end) }
                let run = source.distance(from: index, to: end)
                if codeDelimiter == run { codeDelimiter = nil } else if codeDelimiter == nil { codeDelimiter = run }
                index = end
                continue
            }
            guard codeDelimiter == nil else {
                index = source.index(after: index)
                continue
            }
            switch character {
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            case "(":
                if bracketDepth > 0 { parenthesisDepth += 1 }
            case ")": parenthesisDepth = max(0, parenthesisDepth - 1)
            case "*", "_":
                // Treat delimiter runs conservatively. This intentionally
                // retains a little more tail for prose containing emphasis.
                emphasisDepth = emphasisDepth == 0 ? 1 : 0
            default: break
            }
            index = source.index(after: index)
        }
        return (
            codeDelimiter != nil || bracketDepth > 0 || parenthesisDepth > 0 || emphasisDepth > 0, lastSafeWhitespace
        )
    }
}

/// Holds the live text of the single in-flight Hermes response. Streaming
/// updates publish here instead of mutating DockModel.messages so a 30fps
/// re-render is confined to the one streaming row rather than the whole
/// popover (conversation, sidebar, and composer all observe DockModel).
@MainActor
final class StreamingText: ObservableObject {
    private(set) var text = ""
    @Published private(set) var chunks: [StreamingPresentationChunk] = []

    private static let backgroundThreshold = 2 * StreamingChunkPolicy.maxMutableTailBytes
    private var promotionTask: Task<Void, Never>?
    private var queuedDelta = ""
    private var stableChunks: [StreamingPresentationChunk] = []
    private var mutableTail = ""
    private var mutableTailContext: StreamingChunkContext = .markdown
    private var nextStableChunkID = 0
    private var tailRevision = 0
    private var completionSnapshot: [StreamingPresentationChunk]?
    private var completionSnapshotText = ""
    private var completionSnapshotMessageID: UUID?

    func appendPresentation(_ delta: String) {
        guard !delta.isEmpty else { return }
        text.append(delta)
        apply(StreamingChunkPolicy.prepare(mutableTail + delta, startingIn: mutableTailContext))
    }

    /// Stream deltas arriving during work stay ordered in one queue for this turn only.
    func enqueuePresentation(_ delta: String) {
        guard !delta.isEmpty else { return }
        if promotionTask == nil, queuedDelta.isEmpty, delta.utf8.count <= Self.backgroundThreshold {
            appendPresentation(delta)
        } else {
            queuedDelta.append(delta)
            drainPresentationQueue()
        }
    }

    private func drainPresentationQueue() {
        guard promotionTask == nil, !queuedDelta.isEmpty else { return }
        let delta = queuedDelta
        queuedDelta = ""
        let input = mutableTail + delta
        let context = mutableTailContext
        let worker = Task.detached(priority: .userInitiated) {
            StreamingChunkPolicy.prepare(input, startingIn: context)
        }
        promotionTask = Task { [weak self] in
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.text.append(delta)
            self.apply(prepared)
            self.promotionTask = nil
            self.drainPresentationQueue()
        }
    }

    /// A completed row can prepare its Markdown independently if the live projection is still catching up.
    func reconcileForCompletion(with value: String) -> Bool {
        guard promotionTask == nil,
            value.utf8.count <= Self.backgroundThreshold
                || (value.utf8.count - text.utf8.count <= Self.backgroundThreshold && value.hasPrefix(text))
        else { return false }
        reconcilePresentation(with: value)
        return true
    }

    private func cancelPreparation() {
        promotionTask?.cancel()
        promotionTask = nil
        queuedDelta = ""
    }

    /// Reconciles a completion envelope without replacing the already
    /// promoted prefix. Normal deltas append the missing suffix; a transport
    /// correction still falls back to the exact replacement path.
    func reconcilePresentation(with value: String) {
        guard text != value else { return }
        if value.hasPrefix(text) {
            appendPresentation(String(value.dropFirst(text.count)))
        } else {
            replacePresentation(with: value)
        }
    }

    func replacePresentation(with value: String) {
        cancelPreparation()
        completionSnapshot = nil
        completionSnapshotText = ""
        completionSnapshotMessageID = nil
        stableChunks = []
        nextStableChunkID = 0
        tailRevision &+= 1
        text = value
        apply(StreamingChunkPolicy.prepare(value, startingIn: .markdown))
    }

    func clearPresentation() {
        completionSnapshot = nil
        completionSnapshotText = ""
        completionSnapshotMessageID = nil
        clearLivePresentation()
    }

    /// Retains the already-rendered projection for the one-frame handoff from
    /// the live row to the completed transcript row. The canonical transport
    /// text remains owned by DockModel.
    func retainCompletionPresentation(for messageID: UUID? = nil) {
        completionSnapshot = chunks
        completionSnapshotText = text
        completionSnapshotMessageID = messageID
    }

    /// The outgoing live row can still render before the transcript publishes its completed row.
    func retainedCompletion(for messageID: UUID) -> (text: String, chunks: [StreamingPresentationChunk])? {
        guard completionSnapshotMessageID == messageID, let completionSnapshot else { return nil }
        return (completionSnapshotText, completionSnapshot)
    }

    /// The snapshot belongs to one completed message. Other long rows must
    /// not pay a full-text search on every body evaluation to discover that.
    func completionChunks(matching source: String, messageID: UUID? = nil) -> [StreamingPresentationChunk]? {
        guard let completionSnapshot else { return nil }
        if let messageID, let completionSnapshotMessageID, messageID != completionSnapshotMessageID {
            return nil
        }
        if source.isEmpty { return completionSnapshot }
        let rendered = completionSnapshotText
        guard source.utf8.count <= rendered.utf8.count else { return nil }
        if rendered == source { return completionSnapshot }
        // Bot attribution is removed from the persisted message and its
        // surrounding envelope whitespace is trimmed. Reuse the exact
        // already-promoted chunk projection by slicing that visible suffix;
        // this keeps completion from reparsing the body.
        guard let visibleRange = rendered.range(of: source, options: .backwards) else { return nil }
        var result: [StreamingPresentationChunk] = []
        var cursor = rendered.startIndex
        for chunk in completionSnapshot {
            let chunkEnd = rendered.index(cursor, offsetBy: chunk.text.count)
            let start = cursor < visibleRange.lowerBound ? visibleRange.lowerBound : cursor
            let end = chunkEnd > visibleRange.upperBound ? visibleRange.upperBound : chunkEnd
            if start < end {
                result.append(
                    StreamingPresentationChunk(
                        id: chunk.id,
                        text: String(rendered[start..<end]),
                        revision: chunk.revision,
                        isMutableTail: chunk.isMutableTail,
                        context: chunk.context
                    ))
            }
            cursor = chunkEnd
            if cursor >= visibleRange.upperBound { break }
        }
        return result
    }

    /// Clears live observation without throwing away the projection used by a
    /// completed native row during the SwiftUI identity handoff.
    func clearLivePresentation() {
        cancelPreparation()
        text = ""
        stableChunks = []
        mutableTail = ""
        mutableTailContext = .markdown
        nextStableChunkID = 0
        tailRevision &+= 1
        chunks = []
    }

    private func apply(_ prepared: StreamingChunkPolicy.Promotion) {
        for segment in prepared.stable {
            stableChunks.append(
                StreamingPresentationChunk(
                    id: nextStableChunkID, text: segment.text, revision: tailRevision,
                    isMutableTail: false, context: segment.context))
            nextStableChunkID += 1
        }
        mutableTail = prepared.tail
        mutableTailContext = prepared.context
        tailRevision &+= 1
        publishChunks()
    }

    private func publishChunks() {
        var published = stableChunks
        if !mutableTail.isEmpty {
            published.append(
                StreamingPresentationChunk(
                    id: Int.max,
                    text: mutableTail,
                    revision: tailRevision,
                    isMutableTail: true,
                    context: mutableTailContext
                ))
        }
        chunks = published
    }
}

extension StreamingChunkPolicy {
    static func contextAfter(
        _ source: String,
        startingIn context: StreamingChunkContext
    ) -> StreamingChunkContext {
        var active: MarkdownFence?
        if case .fencedCode(let marker, let length, let language) = context {
            // Keep the authored marker. A shorter fence inside a longer one is
            // literal code and must not close the synthetic continuation.
            active = MarkdownFence(marker: marker, length: length, language: language)
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let fence = active {
                if fence.isClosed(by: line) { active = nil }
            } else if let opening = MarkdownFence(opening: line) {
                active = opening
            }
        }
        if let active {
            return .fencedCode(marker: active.marker, length: active.length, language: active.language)
        }
        let first = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.hasPrefix(">") {
            return .quote(depth: first.prefix(while: { $0 == ">" }).count)
        }
        if let item = first.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
            item.hasPrefix("- ") || item.hasPrefix("* ") || item.hasPrefix("+ ")
        {
            return .list(marker: String(item.first!), indentation: 0)
        }
        if first.hasPrefix("|") || NativeMarkdownAttributedTextBuilder.isPureTable(first) { return .table }
        return .paragraph
    }
}

/// Forwards presentation updates only while the reader is not scrolling.
/// Canonical text continues accumulating in StreamingText during the gesture.
@MainActor
final class StreamingTextPresentation: ObservableObject {
    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()
    private weak var streaming: StreamingText?
    private weak var controller: ConversationScrollController?
    private var sourceChanges: AnyCancellable?
    private var settled: AnyCancellable?
    private var hasPresentedText = false

    func observe(_ streaming: StreamingText, controller: ConversationScrollController?) {
        guard self.streaming !== streaming || self.controller !== controller else { return }
        stopObserving()
        self.streaming = streaming
        self.controller = controller
        hasPresentedText = !streaming.text.isEmpty
        sourceChanges = streaming.objectWillChange.sink { [weak self, weak streaming] in
            guard let self, let streaming else { return }
            guard self.controller?.isUserScrolling != true || !self.hasPresentedText || streaming.text.isEmpty else {
                return
            }
            self.hasPresentedText = !streaming.text.isEmpty
            self.objectWillChange.send()
        }
        settled = controller?.userScrollSettled.sink { [weak self] in
            self?.objectWillChange.send()
        }
        objectWillChange.send()
    }

    func stopObserving() {
        sourceChanges = nil
        settled = nil
        streaming = nil
        controller = nil
    }
}

/// Renders the in-flight response without reflowing it during a manual scroll.
struct StreamingMessageText: View {
    let streaming: StreamingText
    let messageID: UUID
    var completedMarkdown: String? = nil
    var completionChunks: [StreamingPresentationChunk]? = nil
    @Environment(\.conversationScrollController) private var scrollController
    @StateObject private var presentation = StreamingTextPresentation()
    @State private var prepared: MarkdownRenderDocument?

    var body: some View {
        let completion = streaming.retainedCompletion(for: messageID)
        let text = completedMarkdown ?? completion?.text ?? streaming.text
        let chunks = completionChunks ?? completion?.chunks ?? streaming.chunks
        let key = completedMarkdown.map { MarkdownMessageView.renderKey(for: $0) }
        return GenerativeUIIntegration.renderReply(text, streaming: true) {
            standardBody(text: text, chunks: chunks, document: prepared?.source == completedMarkdown ? prepared : nil)
        }
        .task(id: key) {
            guard let key, let completedMarkdown else { return }
            let document = await ConversationMarkdownPrefetch.prepareCompletion(
                completedMarkdown, key: key, controller: scrollController)
            if !Task.isCancelled { prepared = document }
        }
        .onAppear { updateObservation() }
        .onChange(of: completedMarkdown != nil) { _, _ in updateObservation() }
        .onChange(of: ObjectIdentifier(streaming)) { _, _ in
            updateObservation()
        }
        .onChange(of: scrollController.map { ObjectIdentifier($0) }) { _, _ in
            updateObservation()
        }
        .onDisappear { presentation.stopObserving() }
    }

    private func updateObservation() {
        if completedMarkdown == nil {
            presentation.observe(streaming, controller: scrollController)
        } else {
            presentation.stopObserving()
        }
    }

    @ViewBuilder
    private func standardBody(
        text: String, chunks: [StreamingPresentationChunk], document: MarkdownRenderDocument?
    ) -> some View {
        if completedMarkdown != nil || StreamingMarkdownRendererPolicy.usesNativeRenderer(for: text) {
            NativeStreamingMarkdownView(
                chunks: chunks, source: text, themeRevision: DockThemeRuntime.revision, completedDocument: document
            )
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(chunks) { chunk in
                    StreamingChunkText(chunk: chunk)
                        .equatable()
                }
            }
        }
    }
}

/// Incremental native presentation for long live responses. Stable chunks are
/// appended once; only the final mutable chunk is replaced on each flush.
@MainActor
struct NativeStreamingMarkdownView: NSViewRepresentable {
    @Environment(\.conversationScrollController) private var scrollController
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    let chunks: [StreamingPresentationChunk]
    let source: String
    let themeRevision: Int
    var completedDocument: MarkdownRenderDocument? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeMarkdownDocumentContainerView {
        let view = NativeMarkdownDocumentContainerView()
        view.retainsStreamingMeasurements = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownDocumentContainerView, context: Context) {
        nsView.scrollController = scrollController
        nsView.markdownOpenURL = context.environment.markdownOpenURL
        nsView.setBodyStyle(
            size: DockTypography.size(.conversation, scale: context.environment.dockWorkspaceScale), weight: .regular)
        nsView.keepsAccessibilitySectionsMounted = voiceOverEnabled || switchControlEnabled
        context.coordinator.update(
            nsView, chunks: chunks, source: source, themeRevision: themeRevision, completedDocument: completedDocument)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeMarkdownDocumentContainerView,
        context: Context
    ) -> CGSize? {
        NativeMarkdownDocumentSizing.size(for: proposal, view: nsView)
    }

    @MainActor
    final class Coordinator {
        private var renderedThemeRevision: Int?
        private(set) var sectionPreparationCount = 0
        private weak var previousView: NativeMarkdownDocumentContainerView?
        private var previousChunks: [StreamingPresentationChunk] = []
        private var sectionEnds: [Int] = []
        private(set) var preparedSections: [MarkdownRenderSection] = []
        func update(
            _ view: NativeMarkdownDocumentContainerView,
            chunks: [StreamingPresentationChunk],
            source: String,
            themeRevision: Int, completedDocument: MarkdownRenderDocument? = nil
        ) {
            if let completedDocument {
                if !previousChunks.isEmpty {
                    previousChunks.removeAll()
                    sectionEnds.removeAll()
                    preparedSections.removeAll()
                }
                previousView = nil
                view.apply(document: completedDocument)
                return
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let preparationsBefore = sectionPreparationCount
            if renderedThemeRevision != nil, renderedThemeRevision != themeRevision { view.reset() }
            renderedThemeRevision = themeRevision
            var prefix = 0
            while prefix < min(previousChunks.count, chunks.count) {
                let previous = previousChunks[prefix]
                let next = chunks[prefix]
                guard previous == next, previous.text == next.text,
                    previous.context == next.context, previous.isMutableTail == next.isMutableTail
                else { break }
                prefix += 1
            }
            // Stable chunks retain their exact sections and byte offsets; only a changed suffix is classified.
            let retained = prefix == 0 ? 0 : sectionEnds[prefix - 1]
            preparedSections.removeSubrange(retained...)
            sectionEnds.removeSubrange(prefix...)
            var offset = preparedSections.last?.sourceRange.upperBound ?? 0
            for chunk in chunks.dropFirst(prefix) {
                let sections = MarkdownRenderDocumentBuilder.sections(for: [chunk])
                sectionPreparationCount += 1
                preparedSections.append(
                    contentsOf: sections.map { section in
                        MarkdownRenderSection(
                            id: section.id,
                            sourceRange: (section.sourceRange.lowerBound + offset)..<(section.sourceRange.upperBound
                                + offset),
                            source: section.source, kind: section.kind, continuation: section.continuation)
                    })
                offset += chunk.text.utf8.count
                sectionEnds.append(preparedSections.count)
            }
            previousChunks = chunks
            view.applyStreaming(
                sections: preparedSections, source: source, retained: previousView === view ? retained : -1)
            previousView = view
            let tailBytes = chunks.last(where: { $0.isMutableTail })?.text.utf8.count ?? 0
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.writePerformance(
                "markdown_native_update mode=streaming stable_sections=\(chunks.filter { !$0.isMutableTail }.count) prepared_chunks=\(sectionPreparationCount - preparationsBefore) tail_bytes=\(tailBytes) duration_ms=\(String(format: "%.2f", elapsed))"
            )
        }
    }
}

private struct StreamingChunkText: View, Equatable {
    let chunk: StreamingPresentationChunk

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chunk == rhs.chunk
    }

    var body: some View {
        MarkdownMessageView(markdown: Self.source(for: chunk), cacheResult: !chunk.isMutableTail)
            .equatable()
    }

    private static func source(for chunk: StreamingPresentationChunk) -> String {
        switch chunk.context {
        case .markdown, .paragraph, .list, .quote, .table, .inline: return chunk.text
        case .fencedCode(let marker, let length, let language):
            let fence = String(repeating: String(marker), count: length)
            return "\(fence)\(language.map { $0.isEmpty ? "" : "\($0)" } ?? "")\n\(chunk.text)\n\(fence)"
        }
    }
}

/// Metadata shown once the in-flight assistant row has visible text.
struct StreamingResponseMetadata: View {
    let timestamp: Date
    let timeLabel: String
    let modelName: String?
    let responseDuration: TimeInterval?

    var body: some View {
        HStack(spacing: 6) {
            Text(timeLabel)
            ResponseDurationLabel(startedAt: timestamp, finishedDuration: responseDuration)
            if let modelName { Text("· \(modelName)") }
        }
        .dockFont(.machineMetadata)
        .foregroundStyle(Color.dockMetadataText)
        .dockPadding(.horizontal, 4)
    }
}
