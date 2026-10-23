import Foundation

/// Disposable projection of one review conversation; Hermes owns the messages.
@MainActor
final class ReviewGuideReplyModel: ObservableObject {
    @Published private(set) var reply: String?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var identity: String?
    private var generation = UUID()
    private weak var client: HermesRPCClientProtocol?

    func reset(session: HermesSession?) {
        let key = session.map { WorkspaceIdentity.session(profileID: $0.profileID, sessionID: $0.id) }
        guard key != identity else { return }
        identity = key
        generation = UUID()
        reply = nil
        error = nil
        loading = false
    }

    func refresh(session: HermesSession, client: HermesRPCClientProtocol) async {
        if self.client !== client {
            self.client = client
            generation = UUID()
            reply = nil
            error = nil
            loading = false
        }
        reset(session: session)
        guard !loading else { return }
        let token = generation
        loading = true
        defer { if generation == token { loading = false } }
        do {
            let loaded = try await HermesReviewGuideReplyService(client: client).load(session)
            guard !Task.isCancelled, generation == token else { return }
            // A transient empty history must not erase a guide already displayed.
            if let loaded { reply = loaded }
            error = nil
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = DockModel.safeUserDiagnostic(error.localizedDescription)
        }
    }
}
