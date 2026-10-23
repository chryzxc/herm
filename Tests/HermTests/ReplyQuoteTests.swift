import Testing

@testable import Herm

struct ReplyQuoteTests {
    @Test func roundTripsThroughMessageText() throws {
        let quote = ReplyQuote(author: "Forge", text: "line one\nline two: with colon")
        let (parsed, body) = try #require(ReplyQuote.split(quote.composing("my reply\nsecond line")))
        #expect(parsed == quote)
        #expect(body == "my reply\nsecond line")
    }

    @Test func plainAndUserTypedQuotesAreNotReplies() {
        #expect(ReplyQuote.split("hello") == nil)
        #expect(ReplyQuote.split("> just a markdown quote\n\nhi") == nil)
    }

    @Test func longSnippetsAreTruncated() {
        #expect(ReplyQuote(author: "A", text: String(repeating: "x", count: 500)).snippet.count == 141)
    }
}
