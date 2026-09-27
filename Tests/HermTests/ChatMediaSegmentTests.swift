import Testing
@testable import Herm

struct ChatMediaSegmentTests {
    @Test func splitsMediaLinesIntoAttachments() {
        let text = "The file is here:\nMEDIA:/Users/me/report.docx\nTap the attachment above to download it."
        #expect(ChatMediaSegment.split(text) == [
            .markdown("The file is here:"),
            .media("/Users/me/report.docx"),
            .markdown("Tap the attachment above to download it."),
        ])
    }

    @Test func leavesInlineMentionsAndPlainTextAlone() {
        let text = "Use a `MEDIA:` tag like MEDIA:/tmp/x.png to deliver files."
        #expect(ChatMediaSegment.split(text) == [.markdown(text)])
        #expect(ChatMediaSegment.split("hello") == [.markdown("hello")])
    }

    @Test func stripsQuotesAroundPaths() {
        #expect(ChatMediaSegment.split("MEDIA: \"/tmp/a b.pdf\"") == [.media("/tmp/a b.pdf")])
    }
}
