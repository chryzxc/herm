import Combine
import Foundation

/// References and disposable projections only; conversation history stays in Hermes.
@MainActor
final class PullRequestChatStore: ObservableObject {
    private var chats: [String: PullRequestChatModel] = [:]
    private var recentlyPresented: [String] = []
    private let idleLimit = 4

    func chat(for record: PullRequestRecord) -> PullRequestChatModel {
        if let chat = chats[record.id] { return chat }
        let chat = PullRequestChatModel()
        chats[record.id] = chat
        recentlyPresented.append(record.id)
        chat.onRetentionChange = { [weak self, weak chat] in
            if chat?.canRelease == true { self?.pruneIdleChats() }
        }
        return chat
    }

    func setVisible(_ recordID: String, host: UUID, visible: Bool) {
        guard let chat = chats[recordID] else { return }
        if visible {
            chat.visibleHosts.insert(host)
            recentlyPresented.removeAll { $0 == recordID }
            recentlyPresented.append(recordID)
        } else {
            chat.visibleHosts.remove(host)
        }
        pruneIdleChats()
    }

    private func pruneIdleChats() {
        let idle = recentlyPresented.filter { chats[$0]?.canRelease == true }
        guard idle.count > idleLimit else { return }
        let obsolete = Set(idle.dropLast(idleLimit))
        recentlyPresented.removeAll { obsolete.contains($0) }
        for id in obsolete {
            chats.removeValue(forKey: id)?.shutdown()
        }
    }
}

@MainActor
final class PullRequestChatModel: ObservableObject {
    @Published private(set) var conversation: DockModel?
    private let links: UserDefaults
    private var sessionLink: AnyCancellable?
    private var retentionLink: AnyCancellable?
    private var projection: DisposableChatProjection?
    var visibleHosts = Set<UUID>()
    var onRetentionChange: (() -> Void)?
    private var isPreparing = false
    private var automaticContext: ChatContext?

    var canRelease: Bool {
        guard visibleHosts.isEmpty, !isPreparing else { return false }
        guard let model = conversation else { return true }
        return (model.status == .idle || model.status == .offline)
            && !model.isSending && !model.isCreatingSession && !model.isRestoringSession
            && model.streamingMessageID == nil && model.pendingSessionSends.isEmpty
            && model.inFlightBotActivities.isEmpty
            && model.draft.isEmpty && model.pendingImages.isEmpty && model.pendingPDFURLs.isEmpty
            && model.replyQuote == nil
            && model.pendingAttachmentError == nil && model.pendingPDFError == nil && model.composerDrafts.isEmpty
            && model.attachedContexts.allSatisfy { $0 == automaticContext }
    }

    init(links: UserDefaults = .standard) {
        self.links = links
    }

    func linkedDestination(for pr: PullRequestRecord) -> QuickDestination? {
        guard let data = links.data(forKey: "herm.pull-request-chat." + pr.id) else { return nil }
        return try? JSONDecoder().decode(QuickDestination.self, from: data)
    }

    func prepareConversation(for pr: PullRequestRecord, runtime: DockModel) async {
        guard conversation == nil else { return }
        isPreparing = true
        defer {
            isPreparing = false
            onRetentionChange?()
        }
        let linked = linkedDestination(for: pr)
        let projection = DisposableChatProjection(
            surface: .pullRequest, profileID: "default", sessionID: linked?.sessionID, runtime: runtime)
        self.projection = projection
        let model = projection.model
        retentionLink = Publishers.MergeMany(
            model.$status.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            model.$isSending.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            model.$pendingSessionSends.map(\.isEmpty).removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.onRetentionChange?() }
        conversation = model

        sessionLink = model.$sessionStorageID.compactMap { $0 }.sink { [weak self, weak model] sessionID in
            guard let self, let model else { return }
            let destination = QuickDestination(
                profileID: model.sessionProfileID ?? "default", sessionID: sessionID, runtimeID: model.sessionID,
                title: "PR #\(pr.displayNumber)", projectPath: pr.localPath.isEmpty ? nil : pr.localPath)
            if let data = try? JSONEncoder().encode(destination) {
                self.links.set(data, forKey: "herm.pull-request-chat." + pr.id)
            }
            runtime.rememberQuickSession(destination)
        }
        if let session = linked?.session {
            model.isRestoringSession = true
            _ = await model.resumeSession(session, reportFailure: true)
            model.isRestoringSession = false
        } else {
            model.newChat(projectPath: pr.localPath.isEmpty ? nil : pr.localPath)
        }
        let context = ChatContext(pullRequest: pr)
        automaticContext = context
        model.attachedContexts.append(context)
        model.refreshRuntimeModelOptions(sessionID: model.sessionID)
    }

    func shutdown() {
        sessionLink = nil
        retentionLink = nil
        projection?.shutdown(invalidateResume: false)
        projection = nil
        conversation = nil
        automaticContext = nil
    }
}
