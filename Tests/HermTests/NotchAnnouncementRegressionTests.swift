import AppKit
import Combine
import Testing

@testable import Herm

@MainActor
private final class NotchResumeRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "session.resume" else { return [:] }
        return [
            "session_id": params["session_id"] as? String ?? "",
            "messages": [["role": "assistant", "content": "Earlier failure", "is_error": true]],
        ]
    }
}

@MainActor
struct NotchAnnouncementRegressionTests {
    @Test func routineWorkMustNotRequestAutomaticExpansion() {
        let idle = EdgeNotchActivity()
        let working = EdgeNotchActivity(status: .working)
        #expect(!working.shouldAnnounce(after: idle))
        #expect(!EdgeNotchActivity(status: .working, runningCount: 2).shouldAnnounce(after: working))
        #expect(!EdgeNotchActivity(unread: true).shouldAnnounce(after: idle))
        #expect(!idle.shouldAnnounce(after: working))
        #expect(EdgeNotchActivity(status: .needsClarification).shouldAnnounce(after: working))
    }

    @Test func attentionProjectionPreservesKind() {
        var activity = EdgeNotchActivity(sessionNeedsAttention: true, sessionAttentionState: .failed)
        #expect(activity.attentionState == .failed)
        #expect(activity.title == "Failed")
        activity.sessionAttentionState = .clarification
        #expect(activity.attentionState == .clarification)
        #expect(activity.title == "Needs your answer")
        activity.status = .needsApproval
        #expect(activity.attentionState == .approval)
    }

    @Test func structuredErrorAndStoppedTailNeverPublishCompletion() {
        let model = DockModel(initialSessionID: "current")
        let coordinator = HermInterruptionCoordinator()
        model.interruptionCoordinator = coordinator
        var notices: [HermNotice] = []
        let subscription = coordinator.sessionCompletions.sink { notices.append($0) }
        model.receiveGatewayEvent(
            "message.complete",
            params: [
                "session_id": "current", "seq": 1,
                "payload": ["error": ["message": "Failed"]],
            ])
        #expect(notices.isEmpty)
        #expect(coordinator.failures.first?.sourceID == "current")
        model.isDiscardingStoppedTurn = true
        model.receiveGatewayEvent("message.complete", params: ["session_id": "other", "seq": 1, "payload": [:]])
        #expect(notices.map(\.sourceID) == ["other"])
        model.receiveGatewayEvent("message.complete", params: ["session_id": "current", "seq": 2, "payload": [:]])
        #expect(notices.map(\.sourceID) == ["other"])
        #expect(!model.isDiscardingStoppedTurn)
        withExtendedLifetime(subscription) {}
    }

    @Test func acceptedCompletionKeepsOwnerAndDeduplicatesSequence() {
        let model = DockModel(initialSessionID: "current")
        let coordinator = HermInterruptionCoordinator()
        model.interruptionCoordinator = coordinator
        var notices: [HermNotice] = []
        let subscription = coordinator.sessionCompletions.sink { notices.append($0) }
        let event: [String: Any] = ["session_id": "current", "seq": 1, "payload": [:]]
        model.receiveGatewayEvent("message.complete", params: event)
        model.receiveGatewayEvent("message.complete", params: event)
        model.receiveGatewayEvent("message.complete", params: ["session_id": "other", "seq": 1, "payload": [:]])
        #expect(notices.map(\.sourceID) == ["current", "other"])
        withExtendedLifetime(subscription) {}
    }

    @Test func realResumeDoesNotInventCompletion() async throws {
        let coordinator = HermInterruptionCoordinator()
        let model = DockModel(rpcClient: NotchResumeRPC())
        model.interruptionCoordinator = coordinator
        let controller = EdgeDockController(
            model: model, controlCenter: ControlCenterModel(), interruptions: coordinator,
            openQuota: {}, openKanban: { _ in }, openDock: {})
        let session = HermesSession(
            id: "old", title: "Old", preview: "", startedAt: nil, messageCount: 1, source: "test")
        #expect(await model.resumeSession(session, reportFailure: true))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!controller.state.activity.responseCompleted)
        #expect(!controller.state.expanded)
    }

    @Test func mixedAttentionClearsStaleAndResolvedKinds() {
        func row(_ id: String, _ kind: DockActivityState, live: Bool = true) -> EdgeNotchTask {
            EdgeNotchTask(
                id: id, title: id, phase: .attention, statusLabel: "", detail: nil, updatedAt: nil,
                isCurrent: false, isStatusCurrent: live, session: nil, profileID: id, attentionState: kind)
        }
        let state = EdgeNotchState()
        state.tasks = [row("failed", .failed), row("question", .clarification), row("stale", .approval, live: false)]
        #expect(state.sessionRailActivity.attentionState == .clarification)
        #expect(state.sessionRailActivity.blockedBotID == "question")
        state.tasks = [row("failed", .failed)]
        #expect(state.sessionRailActivity.attentionState == .failed)
        state.tasks = []
        #expect(!state.sessionRailActivity.sessionNeedsAttention)
        #expect(state.sessionRailActivity.sessionAttentionState == nil)
    }
}
