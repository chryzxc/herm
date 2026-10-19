import AppKit
import SwiftUI
import Testing
@testable import Herm

@MainActor
struct GenerativeUIIsolationTests {
    private let surface = """
    ```herm-ui
    {"version":1,"id":"example","title":"Example","fallback":"Readable result","kind":"html","html":"<script>throw new Error('must not run')</script>"}
    ```
    """

    @Test func normalBuildDoesNotIncludeExperiment() {
        #if HERM_EXPERIMENTAL_GENERATIVE_UI
        #expect(GenerativeUIIntegration.isCompiledIn)
        #else
        #expect(!GenerativeUIIntegration.isCompiledIn)
        #expect(!GenerativeUIIntegration.isEnabled)
        #expect(GenerativeUIIntegration.preparePrompt("Request") == "Request")
        #expect(GenerativeUIIntegration.plainText(surface) == surface)
        #endif
    }

    @Test func disabledBoundaryKeepsPromptsAndRepliesUnchanged() {
        for text in ["", "Hello", "ANSWER task: Yes", "```swift\nprint(1)\n```", surface] {
            #expect(GenerativeUIIntegration.preparePrompt(text, enabled: false) == text)
            #expect(GenerativeUIIntegration.plainText(text, enabled: false) == text)
        }
    }

    @Test func presentationDoesNotRewriteCanonicalMessagesOrToolArchives() throws {
        let original = ChatMessage(role: .hermes, text: surface)
        #expect(original.text == surface)
        #expect(original.attachingImages([]).text == surface)
        // Optional metadata written by an older experiment remains safely ignorable.
        let old = Data(#"{"id":"old","name":"terminal","input":"","context":"","startedAt":0,"isComplete":true,"facts":{"outcome":"failed"}}"#.utf8)
        let call = try JSONDecoder().decode(ActiveToolCall.self, from: old)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as? [String: Any])
        #expect(call.id == "old" && call.isComplete)
        #expect(saved["facts"] == nil)
    }

    @Test func oldRenderingContextIsHiddenOnlyInPresentation() {
        let stored = "Question\n\n[Herm rendering context v1]\nOld catalog\n[/Herm rendering context]"
        let message = ChatMessage(role: .user, text: stored)
        #expect(message.text == stored)
        #expect(GenerativeUIIntegration.readableText(message) == "Question")
        #expect(GenerativeUIIntegration.displayUserText("Ordinary [Herm rendering context v1] text") == "Ordinary [Herm rendering context v1] text")
    }

    @Test func disabledRendererUsesExistingContent() async throws {
        var appeared = false
        let root = GenerativeUIIntegration.renderReply(surface, enabled: false) {
            Text("Existing conversation renderer").onAppear { appeared = true }
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(appeared)
    }
}
