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
}
