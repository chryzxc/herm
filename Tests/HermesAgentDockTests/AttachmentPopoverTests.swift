import Foundation
import Testing
@testable import HermesAgentDock

struct AttachmentPopoverTests {
    @Test func exposesAttachmentActionsInStableOrder() {
        #expect(AttachmentPopoverAction.allCases.map(\.id) == [
            "files", "folder", "images", "paste-image", "url", "prompt-snippets"
        ])
    }

    @Test func acceptsOnlyHTTPAndHTTPSURLsWithAHost() {
        #expect(AttachmentPopoverPresentation.validatedURL(from: "https://example.com/path")?.absoluteString == "https://example.com/path")
        #expect(AttachmentPopoverPresentation.validatedURL(from: "http://localhost:8080")?.host == "localhost")
        #expect(AttachmentPopoverPresentation.validatedURL(from: "file:///private/secret") == nil)
        #expect(AttachmentPopoverPresentation.validatedURL(from: "javascript:alert(1)") == nil)
        #expect(AttachmentPopoverPresentation.validatedURL(from: "https://") == nil)
    }

    @Test func insertsAValidatedURLWithoutChangingTheExistingDraft() {
        #expect(AttachmentPopoverPresentation.insertingURL("https://example.com", into: "Keep this draft") == "Keep this draft\nhttps://example.com")
        #expect(AttachmentPopoverPresentation.insertingURL(" https://example.com ", into: "") == "https://example.com")
        #expect(AttachmentPopoverPresentation.insertingURL("file:///tmp/a", into: "draft") == nil)
    }

    @Test func promptSnippetsAreNonEmptyAndHaveStableLabels() {
        #expect(AttachmentPopoverPresentation.promptSnippets.map(\.label) == ["Summarize", "Extract action items", "Review this"])
        #expect(AttachmentPopoverPresentation.promptSnippets.allSatisfy { !$0.text.isEmpty })
    }
}
