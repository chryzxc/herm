import Foundation
import Testing
@testable import Herm

struct ScrollPerformanceMeasurementTests {
    @Test func captureScriptRejectsInvalidArgumentsBeforeCreatingOutput() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        for (arguments, profile) in [([], "0"), (["relative"], "0"), ([output.path, "extra"], "0"), ([output.path], "invalid")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [root.appendingPathComponent("Scripts/capture-scroll-performance.sh").path] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["HERM_SCROLL_PERF_PROFILE": profile]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 2)
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func nearestRankAndInvalidSamples() {
        let cases: [([Double], Double?)] = [([], nil), ([7], 7), ([4, 1], 1), ([3, 1, 2], 2), ([2, 2, 2], 2)]
        for (values, expected) in cases {
            #expect(ScrollPerformanceCaptureSupport.percentile(values, 0.5) == expected)
        }
        #expect(ScrollPerformanceCaptureSupport.percentile(Array(1...100).map(Double.init), 0.95) == 95)
        for values in [[-1.0], [Double.nan], [Double.infinity]] {
            #expect(ScrollPerformanceCaptureSupport.summary(values) == nil)
        }
        #expect(ScrollPerformanceCaptureSupport.percentile([1], 1.1) == nil)
    }

    @Test func calibrationNeedsFiveVariableRepetitions() {
        #expect(ScrollPerformanceCaptureSupport.advisoryLimit([1, 2, 3, 4]) == nil)
        #expect(ScrollPerformanceCaptureSupport.advisoryLimit([2, 2, 2, 2, 2]) == nil)
        #expect(ScrollPerformanceCaptureSupport.advisoryLimit([1, 2, 3, 4, 5]) == 7)
    }

    @Test func captureConfigurationRequiresReleaseAndAbsoluteOptIn() {
        #expect(ScrollPerformanceCaptureSupport.outputURL(environment: [:], release: true) == nil)
        #expect(ScrollPerformanceCaptureSupport.outputURL(environment: ["HERM_SCROLL_PERF_OUTPUT": "/fixture"], release: false) == nil)
        #expect(ScrollPerformanceCaptureSupport.outputURL(environment: ["HERM_SCROLL_PERF_OUTPUT": "relative"], release: true) == nil)
    }

    @Test func groupingKeepsSettingsAndRepetitionsSeparateAndEncodesNumericSamples() throws {
        typealias Support = ScrollPerformanceCaptureSupport
        let samples = ["diff.split.wrap", "diff.unified.nowrap"].flatMap { cell in
            (0..<5).flatMap { repetition in
                (0..<3).map { operation in
                    Support.Sample(cell: cell, repetition: repetition, operation: operation,
                        wallMilliseconds: Double(repetition + operation + 1), cpuMilliseconds: 1,
                        processLifetimePeakRSSBytes: 1024)
                }
            }
        }
        let result = Support.aggregate(samples)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.repetitions.count == 5 && $0.repetitions.allSatisfy { $0.count == 3 } })
        #expect(result.allSatisfy { $0.runMedianMinimum == 2 && $0.runMedianMaximum == 6 })
        let encoded = try JSONEncoder().encode(samples)
        let decoded = try JSONDecoder().decode([Support.Sample].self, from: encoded)
        #expect(decoded.count == samples.count)
        // DTO-only check; full capture export privacy still requires a Release capture.
        let environment = ["TRANSCRIPT": "private-transcript-sentinel", "TOKEN": "fake-credential-sentinel"]
        #expect(Support.outputURL(environment: environment, release: true) == nil)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(environment["TRANSCRIPT"]!))
        #expect(!text.contains(environment["TOKEN"]!))
    }
}
