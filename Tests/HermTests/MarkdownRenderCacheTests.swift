import Foundation
import Testing

@testable import Herm

@MainActor
struct MarkdownRenderCacheTests {
    /// Message views share one cache identity, so a key that matches but
    /// carries other content must rebuild rather than reuse the entry.
    @Test func sharedKeyNeverServesAnotherSource() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 7, themeRevision: 0)
        let first = MarkdownRenderDocumentCache.document(for: "first reply", key: key)
        let second = MarkdownRenderDocumentCache.document(for: "second reply", key: key)
        #expect(first.source == "first reply")
        #expect(second.source == "second reply")
        #expect(MarkdownRenderDocumentCache.document(for: "second reply", key: key) == second)
    }

    @Test func sectionMeasurementsKeepTheFourMostRecentWidths() {
        var heights = NativeMarkdownHeightCache()
        for width in [200.0, 300, 400, 500] { heights.store(width / 10, forWidth: width) }
        heights.store(31, forWidth: 300)
        heights.store(32, forWidth: 300)
        heights.store(60, forWidth: 600)
        #expect(heights.height(forWidth: 200) == nil)
        #expect(heights.height(forWidth: 300) == 32)
        #expect(heights.height(forWidth: 400) == 40)
        #expect(heights.height(forWidth: 500) == 50)
        #expect(heights.height(forWidth: 600) == 60)
        heights.removeAll()
        #expect(heights.height(forWidth: 300) == nil)
        #expect(heights.height(forWidth: 600) == nil)
    }
}
