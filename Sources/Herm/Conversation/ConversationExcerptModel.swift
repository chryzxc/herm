import Combine
import Foundation

@MainActor
final class ConversationExcerptModel: ObservableObject {
    @Published private(set) var messages: [String] = []
    @Published private(set) var source: HermesSession?
    @Published private(set) var loading = false
    @Published private(set) var partial = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var ownerIdentity: String?

    func isCurrent(_ owner: DockModel) -> Bool { ownerIdentity == WorkspaceIdentity.session(owner) }
    func load(_ session: HermesSession, owner: DockModel) {
        let token = UUID()
        generation = token
        source = session
        messages = []
        loading = true
        partial = false
        error = nil
        let identity = WorkspaceIdentity.session(owner)
        ownerIdentity = identity
        let client = owner.controlRPCClient
        Task {
            defer { if generation == token { loading = false } }
            do {
                let page = try await HermesConversationExcerptService(client: client).load(session)
                guard generation == token, WorkspaceIdentity.session(owner) == identity,
                    owner.controlRPCClient === client
                else { return }
                messages = page.messages
                partial = page.partial
            } catch {
                if generation == token, WorkspaceIdentity.session(owner) == identity, owner.controlRPCClient === client
                {
                    self.error = DockModel.safeUserDiagnostic(error.localizedDescription)
                }
            }
        }
    }
}
