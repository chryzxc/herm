import Foundation
import Testing

@testable import Herm

struct LocalReviewPresentationTests {
    @Test func preservesSelectionUntilComparisonArrives() {
        #expect(LocalReviewPresentation.selection("saved.swift", visible: [], hasComparison: false) == "saved.swift")
        #expect(
            LocalReviewPresentation.selection("saved.swift", visible: ["other.swift"], hasComparison: true)
                == "other.swift")
        #expect(
            LocalReviewPresentation.selection("saved.swift", visible: ["saved.swift"], hasComparison: true)
                == "saved.swift")
    }

    @Test func retainsFilteredFileUntilItsPatchArrives() {
        #expect(
            LocalReviewPresentation.selection(
                "later.swift", visible: ["first.swift"], hasComparison: true, pending: true) == "later.swift")
        #expect(
            LocalReviewPresentation.selection("later.swift", visible: ["first.swift"], hasComparison: true)
                == "first.swift")
    }

    @Test func reconcilesReplacedAndReorderedMatches() {
        let a = DiffSearchMatch(path: "a", lineIndex: 1, range: NSRange(location: 0, length: 1))
        let b = DiffSearchMatch(path: "b", lineIndex: 1, range: NSRange(location: 0, length: 1))
        let c = DiffSearchMatch(path: "c", lineIndex: 1, range: NSRange(location: 0, length: 1))
        #expect(LocalReviewPresentation.matchIndex(previous: [a, b], index: 1, current: [b, a]) == 0)
        #expect(LocalReviewPresentation.matchIndex(previous: [a, b], index: 1, current: [a, c]) == 1)
        #expect(LocalReviewPresentation.matchIndex(previous: [a], index: 0, current: []) == 0)
    }
}
