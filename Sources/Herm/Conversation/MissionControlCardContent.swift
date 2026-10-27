import Combine
import Foundation

/// Disposable, read-only message tail for a visible dashboard card.
@MainActor
final class MissionControlCardContent: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var generation = UUID()

    func load(session: HermesSession, profileID: String?, client: HermesRPCClientProtocol) async {
        let session = HermesSession(
            id: session.id, profileID: session.profileID ?? profileID, title: session.title,
            preview: session.preview, startedAt: session.startedAt, messageCount: session.messageCount,
            source: session.source)
        let request = UUID()
        generation = request
        loading = true
        error = nil
        defer { if generation == request { loading = false } }
        do {
            let result = try await HermesControlRPC(client: client).sessionMessages(
                sessionID: session.id, profileID: session.profileID, latest: true, limit: 8)
            let page = try HermesConversationExcerptService.parse(result, session: session)
            guard generation == request, !Task.isCancelled else { return }
            text = Self.latestUpdate(page.messages)
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }

    static func preview(_ value: String) -> String? {
        if RichDocument.mentionsSurface(value) {
            let text = GenerativeUIIntegration.plainText(value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return SessionPreviewPresentation.summary(value)
    }

    static func latestUpdate(_ messages: [String]) -> String? {
        let message =
            messages.last { $0.hasPrefix("assistant: ") || $0.hasPrefix("hermes: ") }
            ?? messages.last
        guard let message, let separator = message.range(of: ": ") else { return nil }
        let body = String(message[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : GenerativeUIIntegration.plainText(body)
    }
}
