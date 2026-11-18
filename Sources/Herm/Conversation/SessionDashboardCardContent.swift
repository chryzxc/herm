import Combine
import Foundation

/// Disposable, read-only message tail for a visible dashboard card.
@MainActor
final class SessionDashboardCardContent: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var generation = UUID()
    private static var cache: [String: String] = [:]

    func load(session: HermesSession, profileID: String?, client: HermesRPCClientProtocol) async {
        let stamp = session.lastUpdatedAt?.timeIntervalSince1970 ?? 0
        let session = HermesSession(
            id: session.id, profileID: session.profileID ?? profileID, title: session.title,
            preview: session.preview, startedAt: session.startedAt, messageCount: session.messageCount,
            source: session.source)
        let request = UUID()
        generation = request
        let key = "\(session.scopedID)|\(stamp)"
        // A tile scrolled out and back reuses its last read instead of calling Hermes again.
        if let cached = Self.cache[key] {
            text = cached
            return
        }
        // Fast scrolling cancels tiles before they cost a request.
        try? await Task.sleep(for: .milliseconds(250))
        guard generation == request, !Task.isCancelled else { return }
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let result = try await HermesControlRPC(client: client).sessionMessages(
                sessionID: session.id, profileID: session.profileID, latest: true, limit: 8)
            let page = try HermesConversationExcerptService.parse(result, session: session)
            guard generation == request, !Task.isCancelled else { return }
            text = Self.latestUpdate(page.messages)
            if let text {
                if Self.cache.count > 300 { Self.cache.removeAll() }
                Self.cache[key] = text
            }
            error = nil
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }

    private static var previews: [String: String?] = [:]

    /// `preview` scans for rich surfaces and summarizes; tiles ask on every render.
    static func cachedPreview(_ value: String) -> String? {
        if let cached = previews[value] { return cached }
        if previews.count > 500 { previews.removeAll() }
        let summary = preview(value)
        previews[value] = .some(summary)
        return summary
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

/// A tile's slice of the shared attention, answer and activity streams. Each tile
/// reduces them to its own value, so another chat's change does not re-render it,
/// and it subscribes once while visible instead of on every render.
@MainActor
final class SessionDashboardCardLiveState: ObservableObject {
    @Published private(set) var attention: DockModel.SessionAttention?
    @Published private(set) var answer: AttentionAnswerState?
    @Published private(set) var activity: String?
    private var observedIDs: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    func observe(_ model: DockModel?, ids: [String]) {
        guard let model, cancellables.isEmpty || ids != observedIDs else { return }
        stop()
        observedIDs = ids
        let attention: AnyPublisher<DockModel.SessionAttention?, Never> = model.$sessionAttention
            .map { all in ids.lazy.compactMap { all[$0] }.first }
            .removeDuplicates()
            .eraseToAnyPublisher()
        attention.combineLatest(model.$attentionAnswers)
            .sink { [weak self] attention, answers in
                self?.apply(attention, answer: attention?.responseTarget.flatMap { answers[$0] })
            }
            .store(in: &cancellables)
        model.sessionActivityLabelChanges
            .map { labels in ids.lazy.compactMap { labels[$0] }.first }
            .removeDuplicates()
            .sink { [weak self] label in
                guard let self, self.activity != label else { return }
                self.activity = label
            }
            .store(in: &cancellables)
    }

    private func apply(_ attention: DockModel.SessionAttention?, answer: AttentionAnswerState?) {
        if self.attention != attention { self.attention = attention }
        if self.answer != answer { self.answer = answer }
    }

    func stop() {
        cancellables.removeAll()
    }
}
