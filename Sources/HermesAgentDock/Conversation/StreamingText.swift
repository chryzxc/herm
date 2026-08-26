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
        Label(ResponseDurationFormatting.string(seconds: seconds), systemImage: "stopwatch")
    }
}

/// Holds the live text of the single in-flight Hermes response. Streaming
/// updates publish here instead of mutating DockModel.messages so a 30fps
/// re-render is confined to the one streaming row rather than the whole
/// popover (conversation, sidebar, and composer all observe DockModel).
@MainActor
final class StreamingText: ObservableObject {
    @Published var text = ""
    @Published var reasoning = ""
}

/// Renders the in-flight response. Observing only StreamingText keeps the
/// per-flush re-render inside this row.
struct StreamingMessageText: View {
    @ObservedObject var streaming: StreamingText

    var body: some View {
        Text(streaming.text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .textSelection(.enabled)
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

    var body: some View {
        if !streaming.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    StreamingMessageText(streaming: streaming)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .foregroundStyle(Color.scifiFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.scifiMessageBubble)
                        .clipShape(MessageBubbleShape(isUser: false))
                        .overlay(
                            MessageBubbleShape(isUser: false)
                                .stroke(Color.scifiBorder, lineWidth: 0.5)
                        )

                    HStack(spacing: 6) {
                        Text(HumanDateFormatting.timeOnly(timestamp))
                        ResponseDurationLabel(startedAt: timestamp, finishedDuration: responseDuration)
                        if let modelName {
                            Text("· \(modelName)")
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}
