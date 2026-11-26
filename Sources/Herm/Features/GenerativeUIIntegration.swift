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

    /// Dedicated artifact requests can still carry the full catalog when the plugin is unavailable.
    static func preparePrompt(
        _ text: String, enabled: Bool = isEnabled, context: RichGenerationContext = RichGenerationContext(),
        servedByPlugin: Bool = HermPlugin.isLoaded
    ) -> String {
        let request = displayUserText(text)
        guard enabled else { return request }
        return request + "\n\n" + RichFeatureRegistry.instructions(context: context, servedByPlugin: servedByPlugin)
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
    static func renderMarkdown(_ text: String) -> some View {
        if RichMarkdownPart.isCandidate(text) {
            OptionalRichMarkdown(text: text)
        } else {
            MarkdownMessageView(markdown: text).equatable()
        }
    }

    @MainActor
    static func renderReply(_ text: String) -> some View {
        renderReply(text) { MarkdownMessageView(markdown: text).equatable() }
    }

    @MainActor
    static func renderArtifact(_ text: String) -> some View {
        GenerativeReply(
            text: text, streaming: false, override: nil, visualsOnly: false,
            allowsVisuals: true, fallback: renderMarkdown(text))
    }

    @MainActor @ViewBuilder
    static func renderReply<Content: View>(
        _ text: String, streaming: Bool = false, enabled: Bool? = nil, visualsOnly: Bool = false,
        @ViewBuilder fallback: () -> Content
    ) -> some View {
        GenerativeReply(
            text: text, streaming: streaming, override: enabled, visualsOnly: visualsOnly,
            allowsVisuals: visualsOnly, fallback: fallback())
    }
}

private struct OptionalRichMarkdown: View {
    let text: String
    @AppStorage(GenerativeUIIntegration.preferenceKey) private var enabled = true

    var body: some View {
        if enabled {
            RichMarkdownReply(source: text).id(text)
        } else {
            MarkdownMessageView(markdown: text).equatable()
        }
    }
}

struct RichDocumentParseRequest: Equatable {
    let source: String
    let streaming: Bool
    let identity: String

    // Only append-only, still-unfinished content may retain its inert presentation.
    func canPresent(whileParsing next: Self) -> Bool {
        self == next || (streaming && identity == next.identity && next.source.hasPrefix(source))
    }

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
    let visualsOnly: Bool
    let allowsVisuals: Bool
    let fallback: Content
    @AppStorage(GenerativeUIIntegration.preferenceKey) private var enabled = true
    @State private var parsed: RichDocument?
    @State private var parsedRequest: RichDocumentParseRequest?
    @Environment(\.richReplyContext) private var context
    var body: some View {
        let identity = context?.sourceKey ?? "standalone"
        let request = RichDocumentParseRequest(text, streaming: streaming, identity: identity)
        Group {
            if let request {
                let document = parsedRequest?.canPresent(whileParsing: request) == true ? parsed : nil
                if override ?? (allowsVisuals && enabled) {
                    RichDocumentView(
                        document: document ?? .preparing, enhancesMarkdown: !streaming, visualsOnly: visualsOnly,
                        readOnlySurfaces: streaming || (document != nil && parsedRequest?.streaming == true))
                } else {
                    MarkdownMessageView(markdown: document?.plainText ?? GenerativeUIIntegration.plainText(text))
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
                request.source, streaming: request.streaming)
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
