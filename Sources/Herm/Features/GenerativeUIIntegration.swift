import SwiftUI

/// Single boundary for presentation extensions; Hermes records remain unchanged.
enum GenerativeUIIntegration {
    static let preferenceKey = "herm.generativeUI.enabled"
    static var isCompiledIn: Bool { true }
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static let surfaceID = "herm.generative-ui"

    static func agentSurface(defaults: UserDefaults = .standard) -> HermAgentSurface? {
        guard defaults.object(forKey: preferenceKey) as? Bool ?? true else { return nil }
        return HermAgentSurface(
            id: surfaceID, rules: RichFeatureRegistry.rules, reference: RichFeatureRegistry.reference())
    }

    /// Publishes the records this chat can reference before its prompt is sent.
    @MainActor static func noteGenerationContext(_ context: RichGenerationContext) {
        HermAgentSurfaces.note(
            sessionID: context.sessionID, surface: surfaceID,
            reference: RichFeatureRegistry.sessionReference(context: context))
    }

    /// Keep prompts self-contained until the optional Hermes reference plugin is available.
    static func preparePrompt(
        _ text: String, enabled: Bool = isEnabled, context: RichGenerationContext = RichGenerationContext()
    ) -> String {
        guard enabled else { return text }
        return displayUserText(text) + "\n\n" + RichFeatureRegistry.instructions(context: context)
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
        var text = text
        // Older Herm builds appended the simulator preference after the rendering context.
        if text.hasSuffix("\n</herm-simulator-preference>"),
            let preference = text.range(of: "\n\n<herm-simulator-preference>\n", options: .backwards)
        {
            text = String(text[..<preference.lowerBound])
        }
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

struct RichDocumentParseRequest: Equatable {
    let source: String
    let streaming: Bool
    let identity: String

    init?(_ source: String, streaming: Bool, identity: String) {
        guard RichDocument.mentionsSurface(source) else { return nil }
        self.source = source
        self.streaming = streaming
        self.identity = identity
    }
}

private struct GenerativeReply<Content: View>: View {
    let text: String
    let streaming: Bool
    let override: Bool?
    let fallback: Content
    @AppStorage(GenerativeUIIntegration.preferenceKey) private var enabled = true
    @State private var parsed: RichDocument?
    @State private var parsedRequest: RichDocumentParseRequest?
    @Environment(\.richReplyContext) private var context
    var body: some View {
        let identity = context.map { "\($0.sourceKey):\($0.revision)" } ?? "standalone"
        let request = RichDocumentParseRequest(text, streaming: streaming, identity: identity)
        Group {
            if let request, let document = parsed, parsedRequest == request {
                if override ?? enabled {
                    RichDocumentView(document: document)
                } else {
                    MarkdownMessageView(markdown: document.plainText)
                }
            } else if request != nil {
                if override ?? enabled {
                    Text("Preparing visual reply…").dockFont(.body).foregroundStyle(Color.dockSecondaryText).frame(
                        minHeight: 44)
                } else {
                    MarkdownMessageView(markdown: GenerativeUIIntegration.plainText(text))
                }
            } else {
                fallback
            }
        }
        .task(id: request) {
            guard let request else {
                parsed = nil
                parsedRequest = nil
                return
            }
            let value = await RichDocumentCache.shared.document(
                request.source, identity: request.identity, streaming: request.streaming)
            guard !Task.isCancelled else { return }
            parsed = value
            parsedRequest = request
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
