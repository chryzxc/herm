import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct EdgeResultPeekTests {
    private let session = HermesSession(
        id: "result", profileID: "research", title: "Research",
        preview: "Index preview must never appear", startedAt: nil, messageCount: 0, source: "herm")

    @Test func latestTurnExcludesOldArtifactsAndToolCallPreambles() throws {
        let result = try #require(
            try EdgeResultContent.parse(
                [
                    "session_id": "result",
                    "data": [
                        ["role": "user", "content": "Old task"],
                        ["role": "assistant", "content": "MEDIA:/tmp/old.pdf"],
                        ["role": "user", "content": "New task"],
                        ["role": "assistant", "content": "Generating…", "tool_calls": [["id": "tool"]]],
                        [
                            "role": "tool", "tool_name": "generate_pdf",
                            "content": "{\"output_path\":\"/tmp/new.pdf\"}",
                        ],
                        ["role": "assistant", "content": "Here is the actual result."],
                    ],
                ], session: session))
        #expect(result.text == "Here is the actual result.")
        #expect(result.artifacts.map(\.value) == ["/tmp/new.pdf"])
    }

    @Test func unansweredLatestTurnDoesNotExposePreviousAnswer() throws {
        let result = try EdgeResultContent.parse(
            [
                "data": [
                    ["role": "assistant", "content": "Previous answer"],
                    ["role": "user", "content": "Still waiting"],
                ]
            ], session: session)
        #expect(result == nil)
    }

    @Test func malformedOrWrongOwnerIsRejected() {
        #expect(throws: HermesGateway.GatewayError.self) {
            try EdgeResultContent.parse(["session_id": "other", "data": []], session: session)
        }
        #expect(throws: HermesGateway.GatewayError.self) {
            try EdgeResultContent.parse(["profile": "builder", "data": []], session: session)
        }
        #expect(throws: HermesGateway.GatewayError.self) {
            try EdgeResultContent.parse(["preview": "Fake success"], session: session)
        }
    }

    @Test func multimodalReplyKeepsTextWithoutImagePayload() throws {
        let result = try #require(
            try EdgeResultContent.parse(
                [
                    "data": [
                        [
                            "role": "assistant",
                            "content": [
                                ["type": "text", "text": "Actual answer"],
                                ["type": "image_url", "image_url": ["url": "data:image/png;base64,secret"]],
                            ],
                        ]
                    ]
                ], session: session))
        #expect(result.text == "Actual answer")
        #expect(result.artifacts.isEmpty)
    }

    @Test func renderResultStates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
        let task = EdgeNotchTask(
            id: session.id, title: session.displayTitle, phase: .finished,
            statusLabel: "Finished", detail: nil, updatedAt: nil,
            isCurrent: false, isStatusCurrent: true, session: session)
        for name in ["result-loaded", "result-empty", "result-unavailable"] {
            let view = EdgeResultPeek(
                target: EdgeResultTarget(task: task, session: session),
                load: { session in
                    if name == "result-unavailable" { throw HermesGateway.GatewayError.disconnected }
                    if name == "result-empty" { return nil }
                    return EdgeResultContent(
                        text:
                            "The review is complete.\n\nAll three checks passed. The generated report contains the findings and suggested next steps.\n\nOpen the session to inspect the full tool activity, or reply here to continue the review.",
                        artifacts: [
                            ArtifactRecord(
                                value: "/tmp/herm-result-missing.pdf", sessionID: session.id,
                                sessionTitle: session.displayTitle, timestamp: .now),
                            ArtifactRecord(
                                value: "./reports/review.md", sessionID: session.id,
                                sessionTitle: session.displayTitle, timestamp: .now),
                        ])
                }, back: {}, reply: {}, openSession: {}, showingComparison: .constant(false)
            )
            .frame(width: 352, height: 272)
            .background(Color.dockCanvas)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 352, height: 272)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
