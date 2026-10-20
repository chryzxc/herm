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

    @Test func preferenceDefaultsOnAndChangesImmediately() {
        let key = GenerativeUIIntegration.preferenceKey
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(GenerativeUIIntegration.isEnabled)
        UserDefaults.standard.set(false, forKey: key)
        #expect(!GenerativeUIIntegration.isEnabled)
        #expect(GenerativeUIIntegration.preparePrompt("Request") == "Request")
        UserDefaults.standard.set(true, forKey: key)
        #expect(GenerativeUIIntegration.preparePrompt("Request").contains("Herm rendering context"))
    }

    @Test func normalBuildIncludesVisualsWithReadableDisabledFallback() {
        #expect(GenerativeUIIntegration.isCompiledIn)
        #expect(GenerativeUIIntegration.preparePrompt("Request", enabled: false) == "Request")
        #expect(GenerativeUIIntegration.preparePrompt("Request", enabled: true).contains("Herm rendering context"))
        #expect(GenerativeUIIntegration.plainText(surface, enabled: false).contains("Readable result"))
        #expect(!GenerativeUIIntegration.plainText(surface, enabled: false).contains("<script>"))
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
        let root = GenerativeUIIntegration.renderReply("Plain reply", enabled: false) {
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
