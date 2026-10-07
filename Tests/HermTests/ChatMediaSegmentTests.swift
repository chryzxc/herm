import Testing
@testable import Herm

struct ChatMediaSegmentTests {
    @Test func standaloneMarkdownImageBecomesMedia() {
        #expect(ChatMediaSegment.split("Here:\n![dog](/tmp/dog.png)\nDone") == [
            .markdown("Here:"), .media("/tmp/dog.png"), .markdown("Done"),
        ])
    }

    @Test func producerToolResultsDeliverFiles() {
        func call(_ name: String, _ result: String) -> ActiveToolCall {
            ActiveToolCall(id: name, name: name, input: "", context: "", startedAt: .now, result: result, isComplete: true)
        }
        #expect(ArtifactService.deliveredFiles(in: [
            call("image_generate", #"{"success": true, "image": "https://x.test/dog.png"}"#),
            call("text_to_speech", "MEDIA:/tmp/a.mp3"),
            call("read_file", #"{"path": "/tmp/src.swift"}"#),
        ]) == ["https://x.test/dog.png", "/tmp/a.mp3"])
    }

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
