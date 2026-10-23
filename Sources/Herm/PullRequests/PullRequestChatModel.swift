import Foundation

/// References and disposable projections only; conversation history stays in Hermes.
@MainActor
final class PullRequestChatStore: ObservableObject {
    private var chats: [String: PullRequestChatModel] = [:]
    func chat(for record: PullRequestRecord) -> PullRequestChatModel {
        if let chat = chats[record.id] { return chat }
        let chat = PullRequestChatModel()
        chats[record.id] = chat
        return chat
    }
}

@MainActor
final class PullRequestChatModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var destination: QuickDestination?
    @Published private(set) var messages: [PullRequestChatMessage] = []
    @Published private(set) var sending = false
    @Published private(set) var running = false
    @Published private(set) var needsAttention = false
    @Published private(set) var needsReview = false
    @Published private(set) var error: String?
    private var recovery: QuickDraftRecord?
    private var refreshing = false
    private var submissionRevision = 0

    var canSend: Bool { !sending && !running && !needsReview && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func submit(_ pr: PullRequestRecord, client: HermesRPCClientProtocol, drafts: QuickDraftStore = .shared,
                remember: (QuickDestination) -> Void = { _ in }) async {
        guard canSend else { return }
        var record = recovery ?? QuickDraftRecord(destination: destination ?? QuickDestination(
            profileID: "default", title: "PR #\(pr.displayNumber)", projectPath: pr.localPath.isEmpty ? nil : pr.localPath))
        record.text = text
        record.contexts = [ChatContext(id: pr.id, title: "PR #\(pr.displayNumber)", body:
            "<pull_request_context>\n" + ChatContext(pullRequest: pr).body + "\n</pull_request_context>")]
        record.requestsVisualReply = false
        record.delivery = .submitting
        sending = true
        submissionRevision += 1
        error = nil
        defer { sending = false }
        do {
            drafts.save(record)
            drafts.flush()
            if let error = drafts.error { throw QuickDraftError.message(error) }
            let sent = try await QuickDraftSubmission.send(record, client: client, progress: { updated in
                record = updated
                destination = updated.destination
                remember(updated.destination)
                drafts.save(updated)
                drafts.flush()
                if let error = drafts.error { throw QuickDraftError.message(error) }
            })
            destination = sent.destination
            remember(sent.destination)
            recovery = nil
            text = ""
            running = true
            drafts.remove(sent)
            drafts.flush()
        } catch {
            needsReview = (error as? QuickSubmissionFailure)?.uncertain == true
            record.delivery = needsReview ? .needsReview : .editing
            recovery = record
            destination = record.destination.sessionID == nil ? nil : record.destination
            drafts.save(record)
            drafts.flush()
            self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }

    func refresh(client: HermesRPCClientProtocol) async {
        guard let destination, !refreshing, !sending else { return }
        refreshing = true
        let revision = submissionRevision
        defer { refreshing = false }
        do {
            let snapshot = try await HermesPullRequestChatService(client: client).load(destination)
            guard !Task.isCancelled, revision == submissionRevision else { return }
            // A just-created session can have no saved history while its agent starts.
            if !snapshot.messages.isEmpty { messages = snapshot.messages }
            running = snapshot.isRunning
            needsAttention = snapshot.needsAttention
            if recovery == nil { error = nil }
        } catch {
            guard !Task.isCancelled, revision == submissionRevision else { return }
            if recovery == nil { self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
        }
    }

    func allowDeliberateRetry() {
        guard !sending, needsReview else { return }
        needsReview = false
        recovery?.delivery = .editing
        error = nil
    }
}
