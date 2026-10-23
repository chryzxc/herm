import Testing

@testable import Herm

struct ResultComparisonTests {
    @Test func diffReconstructsBothObservedReads() {
        for (old, new) in [
            ("one\ntwo\nthree", "one\nchanged\nthree"),
            ("a\na\nb", "a\nb\na"), ("", "new"), ("old", ""),
            ("🌟\nreply", "🌟\n更新\nreply"),
        ] {
            let comparison = ResultTextComparison.make(previous: old, current: new)
            #expect(!comparison.usesSeparateSnapshots)
            #expect(
                comparison.lines.filter { $0.kind != .added }.map(\.text).joined(separator: "\n") == old)
            #expect(
                comparison.lines.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n") == new)
        }
    }

    @Test func identicalReadsAndBoundedFallbackAreExplicit() {
        #expect(ResultTextComparison.make(previous: "same", current: "same").identical)
        let long = Array(repeating: "line", count: 401).joined(separator: "\n")
        let comparison = ResultTextComparison.make(previous: long, current: "different")
        #expect(comparison.usesSeparateSnapshots)
        #expect(comparison.lines.isEmpty)
        #expect(!comparison.identical)
        #expect(ResultTextComparison.make(previous: long, current: long).identical)
    }
}
