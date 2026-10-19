import SwiftUI

/// The only boundary between Herm and the optional presentation experiment.
/// Core records stay unchanged; disabled builds use the existing views and prompts.
enum GenerativeUIIntegration {
    static let environmentKey = "HERM_EXPERIMENTAL_GENERATIVE_UI"

    static var isCompiledIn: Bool {
        #if HERM_EXPERIMENTAL_GENERATIVE_UI
        true
        #else
        false
        #endif
    }

    static var isEnabled: Bool {
        isCompiledIn && ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static func preparePrompt(_ text: String, enabled: Bool = isEnabled) -> String {
        #if HERM_EXPERIMENTAL_GENERATIVE_UI
        if enabled { return RichPromptContext.prepare(text) }
        #endif
        return text
    }

    static func plainText(_ text: String, enabled: Bool = isEnabled) -> String {
        #if HERM_EXPERIMENTAL_GENERATIVE_UI
        if enabled { return RichDocument(displayUserText(text)).plainText }
        #endif
        return displayUserText(text)
    }

    static func readableText(_ message: ChatMessage) -> String {
        if message.role == .hermes, message.systemEvent == nil, message.kanbanNotice == nil {
            return plainText(message.text)
        }
        return displayUserText(message.text)
    }

    /// Hide context saved by earlier experimental builds without changing Hermes records.
    static func displayUserText(_ text: String) -> String {
        guard text.hasSuffix("\n[/Herm rendering context]"),
              let context = text.range(of: "\n\n[Herm rendering context v1]\n", options: .backwards)
        else { return text }
        return String(text[..<context.lowerBound])
    }

    @MainActor @ViewBuilder
    static func renderReply<Content: View>(
        _ text: String, streaming: Bool = false, enabled: Bool = isEnabled,
        @ViewBuilder fallback: () -> Content
    ) -> some View {
        #if HERM_EXPERIMENTAL_GENERATIVE_UI
        if enabled, text.contains("herm-ui") {
            let document = RichDocument(text, streaming: streaming)
            if document.hasSurfaces { RichDocumentView(document: document) }
            else { fallback() }
        } else { fallback() }
        #else
        fallback()
        #endif
    }
}

extension View {
    @MainActor @ViewBuilder
    func generativeUISession(model: DockModel) -> some View {
        #if HERM_EXPERIMENTAL_GENERATIVE_UI
        if GenerativeUIIntegration.isEnabled { RichReplySessionScope(model: model, content: self) }
        else { self }
        #else
        self
        #endif
    }

    @MainActor @ViewBuilder
    func generativeUIMessage(model: DockModel, message: ChatMessage) -> some View {
        #if HERM_EXPERIMENTAL_GENERATIVE_UI
        if GenerativeUIIntegration.isEnabled {
            RichReplyMessageScope(model: model, message: message, content: self)
        } else { self }
        #else
        self
        #endif
    }
}
