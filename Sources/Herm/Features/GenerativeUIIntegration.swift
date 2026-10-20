import SwiftUI

/// Single boundary for presentation extensions; Hermes records remain unchanged.
enum GenerativeUIIntegration {
    static let preferenceKey = "herm.generativeUI.enabled"
    static var isCompiledIn: Bool { true }
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func preparePrompt(_ text: String, enabled: Bool = isEnabled) -> String {
        enabled ? RichPromptContext.prepare(text) : text
    }

    /// Text projections remain readable even when visual rendering is disabled.
    static func plainText(_ text: String, enabled: Bool = isEnabled) -> String {
        RichDocument(displayUserText(text)).plainText
    }

    static func readableText(_ message: ChatMessage) -> String {
        message.role == .hermes && message.systemEvent == nil && message.kanbanNotice == nil
            ? plainText(message.text) : displayUserText(message.text)
    }

    static func displayUserText(_ text: String) -> String {
        guard text.hasSuffix("\n[/Herm rendering context]"),
              let context = text.range(of: "\n\n[Herm rendering context v1]\n", options: .backwards)
        else { return text }
        return String(text[..<context.lowerBound])
    }

    @MainActor @ViewBuilder
    static func renderReply<Content: View>(
        _ text: String, streaming: Bool = false, enabled: Bool? = nil,
        @ViewBuilder fallback: () -> Content
    ) -> some View {
        GenerativeReply(text: text, streaming: streaming, override: enabled, fallback: fallback())
    }
}

private struct GenerativeReply<Content: View>: View {
    let text: String
    let streaming: Bool
    let override: Bool?
    let fallback: Content
    @AppStorage(GenerativeUIIntegration.preferenceKey) private var enabled = true
    @State private var parsed: RichDocument?
    @State private var parsedSource: String?
    @State private var parsedStreaming = false
    @Environment(\.richReplyContext) private var context
    var body: some View {
        Group {
            if text.contains("herm-ui"), let document = parsed, parsedSource == text, parsedStreaming == streaming {
                if override ?? enabled { RichDocumentView(document: document) }
                else { MarkdownMessageView(markdown: document.plainText) }
            } else if text.contains("herm-ui") {
                if override ?? enabled {
                    Text("Preparing visual reply…").font(DockTypography.body).foregroundStyle(Color.dockSecondaryText).frame(minHeight: 44)
                } else { MarkdownMessageView(markdown: GenerativeUIIntegration.plainText(text)) }
            } else { fallback }
        }
        .task(id: text + (streaming ? "-streaming" : "-complete")) {
            guard text.contains("herm-ui") else { parsed = nil; parsedSource = nil; return }
            let source = text
            let isStreaming = streaming
            let identity = context.map { "\($0.sourceKey):\($0.revision)" } ?? "standalone"
            let value = await RichDocumentCache.shared.document(source, identity: identity, streaming: isStreaming)
            guard !Task.isCancelled else { return }
            parsed = value; parsedSource = source; parsedStreaming = isStreaming
        }
        .onChange(of: enabled) { _, value in
            if !value { GeneratedHTMLCoordinator.shared.close() }
        }
    }
}

extension View {
    @MainActor func generativeUISession(model: DockModel) -> some View {
        RichReplySessionScope(model: model, content: self)
    }
    @MainActor func generativeUIMessage(model: DockModel, message: ChatMessage) -> some View {
        RichReplyMessageScope(
            model: model, message: message, destination: RichReplyContext.destination(for: model),
            reference: model.storedMessageReferences[message.id], content: self)
    }
}
