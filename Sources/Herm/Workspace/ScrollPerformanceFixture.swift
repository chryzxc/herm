import Foundation

/// Deterministic, side-effect-free data used by the local scroll profiling
/// harness. The harness can feed these rows into the normal presentation
/// surfaces without touching Hermes, persistence, or notifications.
struct ScrollPerformanceFixture: Sendable {
    enum Scenario: String, Sendable {
        case idleLongMarkdown = "idle-long"
        case streamingLongMarkdown = "streaming-long"
        case shortControl = "short-control"
    }
    let projectCount: Int
    let sessionCount: Int
    let messageCount: Int
    let streamingBytes: Int
    let streamingCadenceMilliseconds: Int

    static let standard = ScrollPerformanceFixture(
        projectCount: 30,
        sessionCount: 500,
        messageCount: 500,
        streamingBytes: 131_072,
        streamingCadenceMilliseconds: 250
    )

    var markdownSamples: [String] {
        [
            "# Fixture response\n\nA paragraph with **strong** and `inline code`.",
            "```swift\nlet result = await worker.run()\nprint(result)\n```",
            "| Column | Value |\n| --- | --- |\n| latency | 16ms |\n| rows | 36 |",
            "![fixture image](https://example.invalid/fixture.png)",
        ]
    }

    /// A deterministic long response used by both the idle and streaming
    /// harnesses. Keep the source varied enough to exercise every renderer
    /// path without embedding user data in diagnostics.
    var idleLongMarkdown: String {
        var value = "# Long fixture response\n\n"
        while value.utf8.count < streamingBytes {
            value +=
                "A long fixture paragraph with **strong text**, `inline code`, and [a safe link](https://example.invalid/docs). "
            value += "The transcript remains continuous while the renderer keeps stable sections immutable.\n\n"
            value += "- Stable list item\n- Another list item\n\n"
            value += "> A quoted fixture line remains selectable.\n\n"
            value += "```swift\nlet result = await worker.run()\nprint(result)\n```\n\n"
            value += "| Column | Value |\n| --- | --- |\n| latency | 16ms |\n| rows | 36 |\n\n"
        }
        return String(value.prefix(streamingBytes))
    }

    var streamingLongMarkdown: String { idleLongMarkdown }

    func streamingDeltas(chunkBytes: Int = 37) -> [String] {
        guard chunkBytes > 0 else { return [streamingLongMarkdown] }
        var result: [String] = []
        let source = streamingLongMarkdown
        var start = source.startIndex
        while start < source.endIndex {
            var end = start
            var bytes = 0
            while end < source.endIndex {
                let next = source.index(after: end)
                let characterBytes = source[end..<next].utf8.count
                if bytes > 0, bytes + characterBytes > chunkBytes { break }
                bytes += characterBytes
                end = next
            }
            result.append(String(source[start..<end]))
            start = end
        }
        return result
    }

    /// Feeds the production event boundary rather than mutating the transcript
    /// array per delta. The driver is intentionally metadata-only: fixture
    /// source text never enters the performance log.
    @MainActor
    func runStreaming(on model: DockModel, chunkBytes: Int = 4_096) async {
        let sessionID = model.sessionID ?? "scroll-fixture-session-0"
        model.receiveGatewayEvent("message.start", params: ["session_id": sessionID])
        for delta in streamingDeltas(chunkBytes: chunkBytes) {
            guard !Task.isCancelled else { return }
            model.receiveGatewayEvent("message.delta", params: ["session_id": sessionID, "delta": delta])
            if streamingCadenceMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(streamingCadenceMilliseconds))
            } else {
                await Task.yield()
            }
        }
        guard !Task.isCancelled else { return }
        model.receiveGatewayEvent(
            "message.complete",
            params: [
                "session_id": sessionID,
                "payload": ["text": streamingLongMarkdown, "session_id": sessionID],
            ])
    }

    var sessions: [HermesSession] {
        (0..<sessionCount).map { index in
            HermesSession(
                id: "scroll-fixture-session-\(index)",
                profileID: "scroll-fixture",
                title: "Fixture conversation \(index)",
                preview: "Latest fixture activity for session \(index)",
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                messageCount: index % 17,
                source: "scroll-fixture"
            )
        }
    }

    var messages: [ChatMessage] {
        (0..<messageCount).map { index in
            ChatMessage(
                role: index == messageCount - 1 || index.isMultiple(of: 2) ? .hermes : .user,
                text: index == messageCount - 1
                    ? idleLongMarkdown
                    : markdownSamples[index % markdownSamples.count] + "\n\nFixture message \(index)."
            )
        }
    }

    static var isRequested: Bool {
        requestedScenario != nil
    }

    static var requestedScenario: Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--scroll-perf-fixture") { return .idleLongMarkdown }
        guard let argument = arguments.first(where: { $0.hasPrefix("--scroll-perf-fixture=") }) else { return nil }
        let value = String(argument.dropFirst("--scroll-perf-fixture=".count))
        return Scenario(rawValue: value)
    }
}
