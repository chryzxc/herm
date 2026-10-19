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
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
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

struct StreamingPresentationChunk: Identifiable, Equatable {
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

indirect enum StreamingChunkContext: Equatable {
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

        // A blank line is only a block boundary outside a fenced block.
        // Promoting inside a fence loses the language and parses code as prose.
        var fence: MarkdownFence?
        var start = tail.startIndex
        var bytes = 0
        while let newline = tail[start...].firstIndex(of: "\n") {
            let line = String(tail[start..<newline])
            let end = tail.index(after: newline)
            bytes += tail[start..<end].utf8.count
            if let active = fence {
                if active.isClosed(by: line) { fence = nil }
                if bytes >= targetStableChunkBytes {
                    // Promote the first complete code line past the target,
                    // rather than waiting until the end of an open fence and
                    // inserting one unexpectedly large native section.
                    return end
                }
            } else if let opening = MarkdownFence(opening: line) {
                fence = opening
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty,
                      bytes >= targetStableChunkBytes,
                      !inlineBoundaries(in: tail[..<end]).isUnclosed {
                return end
            }
            start = end
        }
        // A long paragraph (or an open code fence) must not remain one
        // ever-growing mutable Text. Split at a complete line when possible;
        // the streaming renderer carries the fence context for code lines.
        let target = min(maxMutableTailBytes, max(targetStableChunkBytes, tail.utf8.count / 2))
        // Convert the byte budget back to a valid scalar boundary. A response
        // may contain multi-byte Unicode characters, so never slice a UTF-8
        // sequence in the middle.
        let safePrefix = String(decoding: tail.utf8.prefix(target), as: UTF8.self)
        let targetIndex = tail.index(tail.startIndex, offsetBy: safePrefix.count)
        // Find the last safe whitespace in one pass. Rechecking every prefix
        // is quadratic for a long unfinished code span, link, or emphasis.
        return inlineBoundaries(in: tail[..<targetIndex]).lastSafeWhitespace ?? targetIndex
    }

    /// A promoted section is parsed independently. Do not cut through the
    /// common inline constructs whose delimiter may be completed in a later
    /// delta; keeping the construct in the mutable tail preserves its rich
    /// presentation without reparsing stable text.
    private static func inlineBoundaries(in source: Substring) -> (isUnclosed: Bool, lastSafeWhitespace: String.Index?) {
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
               parenthesisDepth == 0, emphasisDepth == 0 {
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
                if codeDelimiter == run { codeDelimiter = nil }
                else if codeDelimiter == nil { codeDelimiter = run }
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
        return (codeDelimiter != nil || bracketDepth > 0 || parenthesisDepth > 0 || emphasisDepth > 0, lastSafeWhitespace)
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
    @Published var reasoning = ""

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
        mutableTail.append(delta)
        promoteStableChunks()
        tailRevision &+= 1
        publishChunks()
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
        completionSnapshot = nil
        completionSnapshotText = ""
        completionSnapshotMessageID = nil
        text = ""
        stableChunks = []
        mutableTail = ""
        mutableTailContext = .markdown
        nextStableChunkID = 0
        tailRevision &+= 1
        text = value
        mutableTail = value
        mutableTailContext = .markdown
        promoteStableChunks()
        tailRevision &+= 1
        publishChunks()
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
        completionSnapshotText = chunks.map(\.text).joined()
        completionSnapshotMessageID = messageID
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
                result.append(StreamingPresentationChunk(
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
        text = ""
        stableChunks = []
        mutableTail = ""
        mutableTailContext = .markdown
        nextStableChunkID = 0
        tailRevision &+= 1
        chunks = []
    }

    private func promoteStableChunks() {
        while let boundary = StreamingChunkPolicy.promotionBoundary(in: mutableTail) {
            let stableText = String(mutableTail[..<boundary])
            stableChunks.append(StreamingPresentationChunk(
                id: nextStableChunkID,
                text: stableText,
                revision: tailRevision,
                isMutableTail: false,
                context: mutableTailContext
            ))
            nextStableChunkID += 1
            mutableTailContext = StreamingChunkPolicy.contextAfter(
                stableText,
                startingIn: mutableTailContext
            )
            mutableTail = String(mutableTail[boundary...])
        }
    }

    private func publishChunks() {
        var published = stableChunks
        if !mutableTail.isEmpty {
            published.append(StreamingPresentationChunk(
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
           item.hasPrefix("- ") || item.hasPrefix("* ") || item.hasPrefix("+ ") {
            return .list(marker: String(item.first!), indentation: 0)
        }
        if first.hasPrefix("|") || NativeMarkdownAttributedTextBuilder.isPureTable(first) { return .table }
        return .paragraph
    }
}

/// Renders the in-flight response. Observing only StreamingText keeps the
/// per-flush re-render inside this row.
struct StreamingMessageText: View {
    @ObservedObject var streaming: StreamingText

    var body: some View {
        GenerativeUIIntegration.renderReply(streaming.text, streaming: true) { standardBody }
    }

    @ViewBuilder
    private var standardBody: some View {
        if streaming.text.utf8.count >= CompletedMarkdownRendererPolicy.nativeThresholdBytes {
            NativeStreamingMarkdownView(streaming: streaming, themeRevision: DockThemeRuntime.revision)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(streaming.chunks) { chunk in
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
    @ObservedObject var streaming: StreamingText
    let themeRevision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeMarkdownDocumentContainerView {
        let view = NativeMarkdownDocumentContainerView()
        context.coordinator.update(view, chunks: streaming.chunks, themeRevision: themeRevision)
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownDocumentContainerView, context: Context) {
        context.coordinator.update(nsView, chunks: streaming.chunks, themeRevision: themeRevision)
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

        func update(
            _ view: NativeMarkdownDocumentContainerView,
            chunks: [StreamingPresentationChunk],
            themeRevision: Int
        ) {
            let started = DispatchTime.now().uptimeNanoseconds
            if renderedThemeRevision != nil, renderedThemeRevision != themeRevision { view.reset() }
            renderedThemeRevision = themeRevision
            let sections = MarkdownRenderDocumentBuilder.sections(for: chunks)
            view.applyStreaming(sections: sections, source: chunks.map(\.text).joined())
            let tailBytes = chunks.last(where: { $0.isMutableTail })?.text.utf8.count ?? 0
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.writePerformance("markdown_native_update mode=streaming stable_sections=\(chunks.filter { !$0.isMutableTail }.count) tail_bytes=\(tailBytes) duration_ms=\(String(format: "%.2f", elapsed))")
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

/// Metadata for the in-flight assistant row. It observes live text because the
/// row itself is an equatable boundary and the placeholder exists (via
/// `message.start`) before the first delta; until text arrives the
/// "Responding" indicator already shows the timer.
struct StreamingResponseMetadata: View {
    @ObservedObject var streaming: StreamingText
    let timestamp: Date
    let timeLabel: String
    let modelName: String?
    let responseDuration: TimeInterval?

    var body: some View {
        if !streaming.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 6) {
                Text(timeLabel)
                ResponseDurationLabel(startedAt: timestamp, finishedDuration: responseDuration)
                if let modelName { Text("· \(modelName)") }
            }
            .font(DockTypography.machineMetadata)
            .foregroundStyle(Color.dockMetadataText)
            .padding(.horizontal, 4)
        }
    }
}

/// Scheduling is bookkeeping, not presentation state. Publishing pending/idle
/// transitions here would invalidate the entire Dock twice per scroll request.
@MainActor
final class ConversationTailScrollScheduler {
    private var task: Task<Void, Never>?

    func schedule(_ action: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(
                    ConversationStreamingPresentationPolicy.tailAdjustmentIntervalMilliseconds
                ))
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
