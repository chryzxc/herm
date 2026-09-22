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
        LucideLabel(ResponseDurationFormatting.string(seconds: seconds), icon: "stopwatch")
    }
}

struct StreamingPresentationChunk: Identifiable, Equatable {
    let id: Int
    let text: String
    let revision: Int
    let isMutableTail: Bool

    nonisolated static func == (
        lhs: StreamingPresentationChunk,
        rhs: StreamingPresentationChunk
    ) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }
}

enum StreamingChunkPolicy {
    static let targetStableChunkBytes = 4_096
    static let maxMutableTailBytes = 8_192

    static func promotionBoundary(in tail: String) -> String.Index? {
        guard tail.utf8.count > maxMutableTailBytes else { return nil }

        var searchStart = tail.startIndex
        while let range = tail.range(of: "\n\n", range: searchStart..<tail.endIndex) {
            if tail[..<range.upperBound].utf8.count >= targetStableChunkBytes {
                return range.upperBound
            }
            searchStart = range.upperBound
        }
        return nil
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
    private var nextStableChunkID = 0
    private var tailRevision = 0

    func appendPresentation(_ delta: String) {
        guard !delta.isEmpty else { return }
        text.append(delta)
        mutableTail.append(delta)
        promoteStableChunks()
        tailRevision &+= 1
        publishChunks()
    }

    func replacePresentation(with value: String) {
        text = ""
        stableChunks = []
        mutableTail = ""
        nextStableChunkID = 0
        tailRevision = 0
        text = value
        mutableTail = value
        promoteStableChunks()
        tailRevision = 1
        publishChunks()
    }

    func clearPresentation() {
        text = ""
        stableChunks = []
        mutableTail = ""
        nextStableChunkID = 0
        tailRevision = 0
        chunks = []
    }

    private func promoteStableChunks() {
        while let boundary = StreamingChunkPolicy.promotionBoundary(in: mutableTail) {
            let stableText = String(mutableTail[..<boundary])
            stableChunks.append(StreamingPresentationChunk(
                id: nextStableChunkID,
                text: stableText,
                revision: 0,
                isMutableTail: false
            ))
            nextStableChunkID += 1
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
                isMutableTail: true
            ))
        }
        chunks = published
    }
}

/// Renders the in-flight response. Observing only StreamingText keeps the
/// per-flush re-render inside this row.
struct StreamingMessageText: View {
    @ObservedObject var streaming: StreamingText

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(streaming.chunks) { chunk in
                StreamingChunkText(chunk: chunk)
                    .equatable()
            }
        }
    }
}

private struct StreamingChunkText: View, Equatable {
    let chunk: StreamingPresentationChunk

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chunk == rhs.chunk
    }

    var body: some View {
        Text(chunk.text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keeps the in-flight assistant placeholder out of the transcript until the
/// first response text has arrived. The live-text observation is important:
/// the placeholder is created by `message.start`, before the first delta.
struct StreamingAssistantMessageRow: View {
    @ObservedObject var streaming: StreamingText
    let timestamp: Date
    let modelName: String?
    let responseDuration: TimeInterval?
    var metrics: ConversationWorkspaceMetrics = .resolve(isFullscreen: false)

    var body: some View {
        if !streaming.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    StreamingMessageText(streaming: streaming)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(HumanDateFormatting.timeOnly(timestamp))
                        ResponseDurationLabel(startedAt: timestamp, finishedDuration: responseDuration)
                        if let modelName {
                            Text("· \(modelName)")
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, metrics.contentInset)
            .padding(.vertical, 8)
        }
    }
}
