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

    @Test func promptRemainsSelfContainedWithoutTheOptionalReferencePlugin() {
        let context = RichGenerationContext(
            profileID: "p", sessionID: "s", availableRecords: [.trace],
            recordReferences: [.init(kind: .trace, id: "s")])
        let prompt = GenerativeUIIntegration.preparePrompt("Explain this", enabled: true, context: context)
        #expect(prompt.contains("Envelope:"))
        #expect(prompt.contains("record.trace (v2)"))
        #expect(!prompt.contains("call herm_reference"))
        #expect(GenerativeUIIntegration.displayUserText(prompt) == "Explain this")
    }

    @Test func preferenceDefaultsOnAndChangesImmediately() {
        let key = GenerativeUIIntegration.preferenceKey
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        let request = """
            Create a savings calculator with starting balance, monthly contribution, annual interest rate, and years.
            """
        UserDefaults.standard.removeObject(forKey: key)
        #expect(GenerativeUIIntegration.isEnabled)
        let prepared = GenerativeUIIntegration.preparePrompt(request)
        #expect(prepared.hasPrefix(request))
        #expect(prepared.contains("When an interactive or structured view helps, use a fenced `herm-ui` JSON object."))
        #expect(prepared.contains("return a working self-contained HTML surface"))
        #expect(prepared.contains("Wire inputs to update results immediately."))
        #expect(prepared.contains("Respect explicit requests for plain text, code listings, or project/file changes"))
        #expect(GenerativeUIIntegration.displayUserText(prepared) == request)
        #expect(GenerativeUIIntegration.preparePrompt(prepared) == prepared)
        UserDefaults.standard.set(false, forKey: key)
        #expect(!GenerativeUIIntegration.isEnabled)
        #expect(GenerativeUIIntegration.preparePrompt(request) == request)
        UserDefaults.standard.set(true, forKey: key)
        #expect(GenerativeUIIntegration.preparePrompt(request) == prepared)
    }

    @Test func legacyInstructionBlocksAreHiddenFromDisplayedPrompts() {
        let rendering = "\n\n[Herm rendering context v1]\nUse herm-ui.\n[/Herm rendering context]"
        let simulator = "\n\n<herm-simulator-preference>\nHerm setting — ON.\n</herm-simulator-preference>"
        #expect(GenerativeUIIntegration.displayUserText("Run it" + rendering + simulator) == "Run it")
        #expect(GenerativeUIIntegration.displayUserText("Run it" + simulator) == "Run it")
        #expect(GenerativeUIIntegration.displayUserText("Run it" + rendering) == "Run it")
        #expect(
            GenerativeUIIntegration.displayUserText("Mentions </herm-simulator-preference>")
                == "Mentions </herm-simulator-preference>")
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
        let old = Data(
            #"{"id":"old","name":"terminal","input":"","context":"","startedAt":0,"isComplete":true,"facts":{"outcome":"failed"}}"#
                .utf8)
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
        #expect(
            GenerativeUIIntegration.displayUserText("Ordinary [Herm rendering context v1] text")
                == "Ordinary [Herm rendering context v1] text")
    }

    @Test func ordinaryStreamingDoesNotRestartRichParsingAndRichRequestsInvalidate() throws {
        var text = "# Ordinary Markdown\n\n"
        for _ in 0..<100 {
            text += "Another **streaming** chunk.\n"
            #expect(RichDocumentParseRequest(text, streaming: true, identity: "session/message:1") == nil)
        }
        #expect(RichDocumentParseRequest(text, streaming: false, identity: "session/message:1") == nil)
        let live = try #require(RichDocumentParseRequest(surface, streaming: true, identity: "session/message:1"))
        let completed = try #require(RichDocumentParseRequest(surface, streaming: false, identity: "session/message:1"))
        #expect(live != completed)
        #expect(
            completed
                != RichDocumentParseRequest(surface + "\nNew content", streaming: false, identity: completed.identity))
        #expect(completed != RichDocumentParseRequest(surface, streaming: false, identity: "another-session/message:1"))
        #expect(completed != RichDocumentParseRequest(surface, streaming: false, identity: "session/message:2"))
        #expect(RichDocument(live.source, streaming: live.streaming).segments == [.pending])
        #expect(RichDocument(completed.source, streaming: completed.streaming).plainText.contains("Readable result"))
    }

    @Test func rendererReturnsToTheOrdinaryFallbackAfterRichContent() async throws {
        var appearances = 0
        var disappearances = 0
        func reply(_ text: String, streaming: Bool) -> some View {
            GenerativeUIIntegration.renderReply(text, streaming: streaming, enabled: false) {
                Text("Existing renderer")
                    .onAppear { appearances += 1 }
                    .onDisappear { disappearances += 1 }
            }
        }
        let host = NSHostingView(rootView: reply("Plain reply", streaming: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(appearances == 1)
        for index in 0..<5 {
            host.rootView = reply("Plain reply, chunk \(index)", streaming: true)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(appearances == 1)
        #expect(disappearances == 0)
        host.rootView = reply(surface, streaming: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(disappearances == 1)
        host.rootView = reply(surface, streaming: false)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(appearances == 1)
        host.rootView = reply("Next ordinary reply", streaming: false)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(appearances == 2)
    }

    @Test func disabledRendererUsesExistingContent() async throws {
        var appeared = false
        let root = GenerativeUIIntegration.renderReply("Plain reply", enabled: false) {
            Text("Existing conversation renderer").onAppear { appeared = true }
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(appeared)
    }
}
