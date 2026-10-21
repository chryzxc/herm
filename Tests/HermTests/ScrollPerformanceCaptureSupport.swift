import Foundation
import Darwin
@testable import Herm

/// Test-only numeric export. No transcript, error descriptions, or environment dump.
enum ScrollPerformanceCaptureSupport {
    struct Sample: Codable {
        let cell: String
        let repetition: Int
        let operation: Int
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let processLifetimePeakRSSBytes: Int
    }

    struct CellSummary: Codable {
        let cell: String
        let repetitions: [Summary]
        let runMedianMinimum: Double
        let runMedianMaximum: Double
        let advisoryP95Milliseconds: Double?
    }

    static func aggregate(_ samples: [Sample]) -> [CellSummary] {
        Dictionary(grouping: samples, by: \.cell).keys.sorted().compactMap { cell in
            let rows = samples.filter { $0.cell == cell }
            let groups = Dictionary(grouping: rows, by: \.repetition)
            let summaries = groups.keys.sorted().compactMap { summary(groups[$0]!.map(\.wallMilliseconds)) }
            guard let low = summaries.map(\.median).min(), let high = summaries.map(\.median).max() else { return nil }
            return CellSummary(cell: cell, repetitions: summaries, runMedianMinimum: low,
                               runMedianMaximum: high, advisoryP95Milliseconds: advisoryLimit(summaries.map(\.p95)))
        }
    }

    struct Summary: Codable, Equatable {
        let count: Int
        let median: Double
        let p95: Double
        let maximum: Double
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty, fraction.isFinite, (0...1).contains(fraction),
              values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return values.sorted()[max(0, Int(ceil(fraction * Double(values.count))) - 1)]
    }

    static func summary(_ values: [Double]) -> Summary? {
        guard let median = percentile(values, 0.5), let p95 = percentile(values, 0.95),
              let maximum = values.max() else { return nil }
        return Summary(count: values.count, median: median, p95: p95, maximum: maximum)
    }

    static func advisoryLimit(_ repetitionP95: [Double]) -> Double? {
        guard repetitionP95.count == 5, let median = percentile(repetitionP95, 0.5),
              let deviation = repetitionP95.map({ abs($0 - median) }).max(), deviation > 0 else { return nil }
        return median + 2 * deviation
    }

    static func outputURL(environment: [String: String], release: Bool) -> URL? {
        guard release, let path = environment["HERM_SCROLL_PERF_OUTPUT"], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static let visits = Array(0..<20) + Array((0..<20).reversed())
    static let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000085")!

    static var pipeline: [AgentActivityPresentation.PipelineActivity] {
        (0..<1008).map {
            .init(id: "scroll-event-\($0)", timestamp: Date(timeIntervalSince1970: Double($0)),
                  status: $0 < 1000 ? "Completed" : "Running", task: "Fixture task \($0)",
                  agent: "Fixture", detail: nil, diffPreview: nil)
        }
    }

    static var patch: String {
        "@@ -1,10000 +1,10000 @@\n" + (0..<10000).map {
            "-old \($0) " + String(repeating: "a", count: 160) + "\n+new \($0) " + String(repeating: "b", count: 160)
        }.joined(separator: "\n")
    }
}
