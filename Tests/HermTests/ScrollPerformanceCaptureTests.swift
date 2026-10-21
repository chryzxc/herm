import AppKit
import Darwin
import Foundation
import Testing
@testable import Herm

@MainActor
@Suite(.serialized)
struct ScrollPerformanceCaptureTests {
    typealias Support = ScrollPerformanceCaptureSupport

    private func usage() -> (Double, Int) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1000
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1000
        return (cpu, Int(value.ru_maxrss))
    }

    @Test func capture() async throws {
        #if DEBUG
        let release = false
        #else
        let release = true
        #endif
        guard let output = Support.outputURL(environment: ProcessInfo.processInfo.environment, release: release) else { return }
        // Guard precedes AppKit, fixture creation, files, defaults and model construction.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try String(getpid()).write(to: output.appendingPathComponent("capture.pid"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["HERM_SCROLL_PERF_PROFILE"] == "1" {
            try await Task.sleep(for: .seconds(15))
        }
        let fixture = ScrollPerformanceFixture.standard
        let source = fixture.idleLongMarkdown
        let messages = fixture.messages
        let pipeline = Support.pipeline
        let patch = Support.patch
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawURL = output.appendingPathComponent("samples.jsonl")
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        let raw = try FileHandle(forWritingTo: rawURL)
        defer { try? raw.close() }
        var samples: [Support.Sample] = []
        func measure(_ cell: String, _ repetition: Int, _ operation: Int, _ body: () -> Void) throws {
            let before = usage().0
            let start = ContinuousClock.now
            body()
            let elapsed = start.duration(to: .now).components
            let after = usage()
            guard repetition >= 0 else { return }
            let sample = Support.Sample(cell: cell, repetition: repetition, operation: operation,
                wallMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                cpuMilliseconds: max(0, after.0 - before), processLifetimePeakRSSBytes: after.1)
            samples.append(sample)
            try raw.write(contentsOf: encoder.encode(sample) + Data([10]))
        }
        let key = MarkdownRenderKey(messageID: Support.messageID, contentRevision: 1, themeRevision: 1)
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        for repetition in -1..<5 {
            let warm = NativeMarkdownDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            warm.apply(document: document)
            _ = warm.intrinsicContentSize
            var range = ConversationMessageWindow.tailRange(totalCount: messages.count)
            for operation in 0..<100 {
                try autoreleasepool {
                    try measure("idle.prepare", repetition, operation) {
                        _ = MarkdownRenderDocumentBuilder.build(source: source, key: key)
                    }
                    let cold = NativeMarkdownDocumentContainerView(frame: warm.frame)
                    try measure("idle.cold.apply", repetition, operation) { cold.apply(document: document) }
                    try measure("idle.cold.layout", repetition, operation) {
                        _ = cold.intrinsicContentSize
                        cold.layoutSubtreeIfNeeded()
                    }
                    try measure("idle.warm.layout", repetition, operation) {
                        _ = warm.intrinsicContentSize
                        warm.layoutSubtreeIfNeeded()
                    }
                    try measure("history.paging", repetition, operation) {
                        let visible = range.lowerBound...min(range.lowerBound + 2, range.upperBound - 1)
                        range = ConversationMessageWindow.revealEarlier(range, totalCount: messages.count, visibleSpan: visible)
                    }
                    try measure("activity.projection", repetition, operation) {
                        let result = SessionActivityOverviewPresentation.makeSnapshot(
                            agentSnapshot: AgentPresentationSnapshot(displayedSubagents: [], pipeline: pipeline,
                                activityCountsByAgentID: [:], activeAgentIDs: [], revision: 1),
                            botRecords: [], kanbanTasks: [])
                        precondition(!result.timeline.isEmpty)
                    }
                }
            }
            for operation in 0..<100 {
                try measure("diff.parse.bounded-prefix", repetition, operation) {
                    let diff = DiffDocument(path: "fixture.swift", patch: patch)
                    precondition(diff.isTruncated)
                }
            }
        }
        try encoder.encode(Support.aggregate(samples)).write(to: output.appendingPathComponent("summary.json"))
        let retainedDiff = DiffDocument(path: "fixture.swift", patch: patch)
        let unavailable: [String: Any] = [
            "schema": 1, "configuration": "release", "scope": "synthetic test process, main-actor operations",
            "boundsPoints": [1000, 700], "repetitions": 5, "warmups": 1,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "appearance": "host native appearance; SwiftUI theme not instantiated",
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "frames": NSNull(), "framesReason": "No compositor capture; layout timing is not frame delivery",
            "hitches": NSNull(), "hitchesReason": "No safe native frame capture available",
            "footprintBytes": NSNull(), "footprintReason": "getrusage supplies process-lifetime peak RSS, not footprint",
            "sharedMemoryBytes": NSNull(), "sharedMemoryReason": "Not measured",
            "mainThreadProfile": NSNull(), "mainThreadProfileReason": "See optional profiler-status.txt; wall samples are not stack samples",
            "displayRefreshHz": NSNull(), "displayRefreshReason": "No display-bound rendering in this host",
            "ownedBrowserCount": 0,
            "rpcRequests": NSNull(), "rpcRequestsReason": "No model or transport instantiated",
            "diffSourceBytes": patch.utf8.count, "diffTruncated": retainedDiff.isTruncated,
            "diffRetainedBytes": retainedDiff.patch.utf8.count, "diffRetainedLines": retainedDiff.lines.count,
            "diffNativeLayout": NSNull(), "diffNativeLayoutReason": "Deferred native preparation is not measured",
            "browserEnabled": NSNull(), "browserEnabledReason": "No browser lifecycle instantiated",
            "streamingNativeUpdates": NSNull(), "streamingNativeUpdatesReason": "Not measured; completion work cannot be isolated by this synchronous harness"
        ]
        try JSONSerialization.data(withJSONObject: unavailable, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("metadata.json"))
    }
}
