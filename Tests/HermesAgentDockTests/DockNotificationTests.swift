import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
private final class InterruptTestRPCClient: HermesRPCClientProtocol {
    enum TestError: Error { case rejected }

    enum Result {
        case success([String: Any])
        case failure(TestError)
    }

    let result: Result
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var interruptCallCount = 0
    private(set) var requests: [(method: String, params: [String: Any])] = []

    init(result: Result) { self.result = result }
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        interruptCallCount += method == "session.interrupt" ? 1 : 0
        switch result {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
    func close() {}
}

@MainActor
private final class SessionProjectionTestRPCClient: HermesRPCClientProtocol {
    enum TestError: Error { case rejected }
    enum Result {
        case success([String: Any])
        case failure(TestError)
    }

    var results: [String: [Result]]
    var onEvent: ((String, [String: Any]) -> Void)?

    init(results: [String: [Result]]) { self.results = results }
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let result = results[method]?.isEmpty == false ? results[method]!.removeFirst() : .failure(.rejected)
        switch result {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
    func close() {}
}

@MainActor
private final class LatestActivityProjectionRPCClient: HermesRPCClientProtocol {
    enum TestError: Error { case rejected }
    var onEvent: ((String, [String: Any]) -> Void)?
    var pages: [[String: Any]]
    let messages: [String: Any]
    private(set) var sessionPagePaths: [String] = []

    init(pages: [[String: Any]], messages: [String: Any]) {
        self.pages = pages
        self.messages = messages
    }

    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        throw TestError.rejected
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.contains("/messages?") { return messages }
        sessionPagePaths.append(path)
        guard path.contains("limit=100") else { throw TestError.rejected }
        guard !pages.isEmpty else { throw TestError.rejected }
        return pages.removeFirst()
    }
    func close() {}
}


@MainActor
private final class ControllableInterruptRPCClient: HermesRPCClientProtocol {
    enum TestError: Error { case rejected }
    var onEvent: ((String, [String: Any]) -> Void)?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var release: CheckedContinuation<Void, Never>?

    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "session.interrupt" else { return [:] }
        didStart = true
        started?.resume()
        started = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            release = continuation
        }
        throw TestError.rejected
    }
    func close() {}

    func waitUntilInterruptStarts() async {
        if didStart { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            started = continuation
        }
    }

    func releaseInterrupt() {
        release?.resume()
        release = nil
    }
}

@MainActor
struct DockNotificationTests {
    @Test func clarificationRequestStopsWorkingStateAndPreservesChoices() {
        let model = DockModel(initialSessionID: "session-clarify")
        model.receiveGatewayEvent("clarify.request", params: [
            "session_id": "session-clarify",
            "payload": [
                "question": "Which task list should I check?",
                "request_id": "clarify-123",
                "choices": ["Personal", "Work"]
            ]
        ])

        #expect(model.status == .needsClarification)
        #expect(model.clarificationQuestion == "Which task list should I check?")
        #expect(model.clarificationChoices == ["Personal", "Work"])
        #expect(model.clarificationRequestID == "clarify-123")
        #expect(!model.isSending)
        #expect(model.messages.last?.role == .hermes)
        #expect(model.messages.last?.text.contains("Which task list should I check?") == true)
        #expect(model.messages.last?.text.contains("- Personal") == true)
        #expect(model.messages.last?.text.contains("- Work") == true)
    }

    @Test func clarificationReplyUsesHermesRequestIDAndAnswerFields() async throws {
        let client = InterruptTestRPCClient(result: .success(["status": "ok"]))
        let model = DockModel(initialSessionID: "session-clarify", rpcClient: client)
        model.receiveGatewayEvent("clarify.request", params: [
            "session_id": "session-clarify",
            "payload": ["request_id": "clarify-123", "question": "Which task list?"]
        ])

        model.respondToClarification("Work")
        await Task.yield()

        let request = try #require(client.requests.first(where: { $0.method == "clarify.respond" }))
        #expect(request.params["request_id"] as? String == "clarify-123")
        #expect(request.params["answer"] as? String == "Work")
        #expect(request.params["response"] == nil)
        #expect(model.clarificationQuestion == nil)
    }

    @Test func clarificationResumeAppendsTheNextHermesReplyAfterTheAnswer() {
        let client = InterruptTestRPCClient(result: .success(["status": "ok"]))
        let model = DockModel(initialSessionID: "session-clarify", rpcClient: client)
        model.receiveGatewayEvent("clarify.request", params: [
            "session_id": "session-clarify",
            "payload": ["request_id": "clarify-123", "question": "Which task list?"]
        ])

        model.respondToClarification("Work")
        model.receiveGatewayEvent("message.delta", params: [
            "session_id": "session-clarify",
            "payload": ["delta": "I'll check Work."]
        ])
        model.receiveGatewayEvent("message.complete", params: [
            "session_id": "session-clarify", "payload": [:]
        ])

        #expect(model.messages.map(\.text) == ["Which task list?", "Work", "I'll check Work."])
    }

    @Test func clarificationResumeDoesNotDuplicateAnAssistantRowWhenMessageStartArrivesLate() {
        let client = InterruptTestRPCClient(result: .success(["status": "ok"]))
        let model = DockModel(initialSessionID: "session-clarify", rpcClient: client)
        model.receiveGatewayEvent("clarify.request", params: [
            "session_id": "session-clarify",
            "payload": ["request_id": "clarify-123", "question": "Which task list?"]
        ])

        model.respondToClarification("Work")
        model.receiveGatewayEvent("message.delta", params: [
            "session_id": "session-clarify", "payload": ["delta": "I'll check Work."]
        ])
        model.receiveGatewayEvent("message.start", params: [
            "session_id": "session-clarify", "payload": [:]
        ])
        model.receiveGatewayEvent("message.complete", params: [
            "session_id": "session-clarify", "payload": [:]
        ])

        #expect(model.messages.map(\.text) == ["Which task list?", "Work", "I'll check Work."])
    }

    @Test func replayedClarificationRequestDoesNotAppendItsQuestionAgain() {
        let client = InterruptTestRPCClient(result: .success(["status": "ok"]))
        let model = DockModel(initialSessionID: "session-clarify", rpcClient: client)
        let event: [String: Any] = [
            "session_id": "session-clarify",
            "payload": ["request_id": "clarify-123", "question": "Which task list?"]
        ]

        model.receiveGatewayEvent("clarify.request", params: event)
        model.respondToClarification("Work")
        model.receiveGatewayEvent("clarification.request", params: event)

        #expect(model.messages.map(\.text) == ["Which task list?", "Work", ""])
        #expect(model.status == .working)
    }

    @Test func interruptReleasesPendingClarificationForNormalPrompting() async {
        let model = DockModel(
            initialSessionID: "session-clarify",
            rpcClient: InterruptTestRPCClient(result: .success(["accepted": true]))
        )
        model.receiveGatewayEvent("clarify.request", params: [
            "session_id": "session-clarify",
            "payload": ["question": "Which task list?"]
        ])
        #expect(model.status == .needsClarification)

        let task = model.stop()
        await task?.value

        #expect(model.interruptState == .requesting)
        #expect(model.clarificationQuestion == "Which task list?")
        #expect(model.clarificationChoices.isEmpty)

        model.receiveGatewayEvent("message.complete", params: [
            "session_id": "session-clarify",
            "payload": [:]
        ])

        #expect(model.interruptState == .idle)
        #expect(model.status == .idle)
    }

    @Test func rejectedInterruptPreservesActiveConversationState() async {
        let client = InterruptTestRPCClient(result: .failure(InterruptTestRPCClient.TestError.rejected))
        let model = DockModel(initialSessionID: "session-interrupt", rpcClient: client)
        model.receiveGatewayEvent("message.start", params: [
            "session_id": "session-interrupt",
            "payload": [:]
        ])
        model.receiveGatewayEvent("approval.request", params: [
            "session_id": "session-interrupt",
            "payload": ["command": "git push"]
        ])
        let tool = ActiveToolCall(id: "tool-1", name: "shell", input: "{}", context: "", startedAt: .now, result: nil, isComplete: false)
        model.activeToolCalls = [tool]

        let task = model.stop()
        await task?.value

        #expect(model.interruptState.isFailed)
        #expect(model.status == .needsApproval)
        #expect(model.approvalText == "git push")
        #expect(model.activeToolCalls == [tool])
        #expect(model.streamingMessageIDForPresentation != nil)
    }

    @Test func acceptedInterruptWaitsForAuthoritativeTerminalEvent() async {
        let client = InterruptTestRPCClient(result: .success(["accepted": true]))
        let model = DockModel(initialSessionID: "session-interrupt", rpcClient: client)
        model.receiveGatewayEvent("message.start", params: [
            "session_id": "session-interrupt",
            "payload": [:]
        ])
        model.status = .working

        let task = model.stop()
        await task?.value

        #expect(model.interruptState == .requesting)
        #expect(model.streamingMessageIDForPresentation != nil)
        #expect(model.status == .working)

        model.receiveGatewayEvent("message.complete", params: [
            "session_id": "session-interrupt",
            "payload": [:]
        ])

        #expect(model.interruptState == .idle)
        #expect(model.status == .idle)
        #expect(model.streamingMessageIDForPresentation == nil)
    }

    @Test func duplicateStopTapsDoNotIssueAnotherInterrupt() async {
        let client = InterruptTestRPCClient(result: .success(["accepted": true]))
        let model = DockModel(initialSessionID: "session-interrupt", rpcClient: client)
        model.status = .working

        let first = model.stop()
        let second = model.stop()
        await first?.value
        await second?.value

        #expect(client.interruptCallCount == 1)
        #expect(model.interruptState == .requesting)
    }

    @Test func inFlightInterruptCannotFailAfterSessionSwitch() async {
        let client = ControllableInterruptRPCClient()
        let model = DockModel(initialSessionID: "old-session", rpcClient: client)
        let task = model.stop()
        await client.waitUntilInterruptStarts()

        model.newChat()
        client.releaseInterrupt()
        await task?.value

        #expect(model.sessionID == nil)
        #expect(model.interruptState == .idle)
    }

    @Test func completedTurnMarksQueuedSteeringMessagesApplied() {
        let model = DockModel(initialSessionID: "session-steer")
        model.receiveGatewayEvent("message.start", params: [
            "session_id": "session-steer",
            "payload": [:]
        ])
        let steerMessage = ChatMessage(
            role: .user,
            text: "Prefer the second option",
            isSteering: true,
            steeringStatus: "QUEUED"
        )
        model.messages.append(steerMessage)
        model.receiveGatewayEvent("message.delta", params: [
            "session_id": "session-steer",
            "payload": ["delta": "The response influenced by the steer."]
        ])

        model.receiveGatewayEvent("message.complete", params: [
            "session_id": "session-steer",
            "payload": [:]
        ])

        #expect(model.messages.map(\.text) == ["The response influenced by the steer.", "Prefer the second option"])
        #expect(model.messages.last?.isSteering == true)
        #expect(model.messages.last?.steeringStatus == "QUEUED")

        model.receiveGatewayEvent("message.start", params: [
            "session_id": "session-steer",
            "payload": [:]
        ])
        model.receiveGatewayEvent("message.delta", params: [
            "session_id": "session-steer",
            "payload": ["delta": "The next response uses the steer."]
        ])
        model.receiveGatewayEvent("message.complete", params: [
            "session_id": "session-steer",
            "payload": [:]
        ])

        #expect(model.messages.map(\.text) == [
            "The response influenced by the steer.",
            "Prefer the second option",
            "The next response uses the steer."
        ])
        #expect(model.messages[1].steeringStatus == "APPLIED")
    }

    @Test func unselectedSessionCannotProjectGatewayActivity() {
        let model = DockModel()

        model.receiveGatewayEvent("approval.request", params: [
            "session_id": "other-session",
            "payload": ["command": "git push"]
        ])

        #expect(model.approvalText == nil)
        #expect(model.recentEvents.isEmpty)
    }

    @Test func switchingSessionsClearsPendingApprovalFromPreviousSession() {
        let model = DockModel(initialSessionID: "session-approval")
        model.receiveGatewayEvent("approval.request", params: [
            "session_id": "session-approval",
            "payload": ["command": "git push"]
        ])

        #expect(model.approvalText == "git push")

        model.newChat()

        #expect(model.approvalTitle == nil)
        #expect(model.approvalText == nil)
        #expect(model.status == .idle)
    }

    @Test func completionNotificationsAreOptIn() {
        let model = DockModel()
        model.setCompletionNotificationsEnabled(true)
        #expect(model.completionNotificationsEnabled == true)
        model.setCompletionNotificationsEnabled(false)
        #expect(model.completionNotificationsEnabled == false)
    }

    @Test func composerFocusRequestIsObservableByThePopover() {
        let model = DockModel()
        let initial = model.composerFocusRequest

        model.requestComposerFocus()

        #expect(model.composerFocusRequest == initial &+ 1)
    }

    @Test func hiddenUpdatesRemainUnreadUntilThePopoverOpens() {
        let model = DockModel()

        model.markPopoverHidden()
        model.markUnreadUpdate()
        #expect(model.hasUnreadResponse)

        model.markPopoverVisible()
        #expect(!model.hasUnreadResponse)
    }

    @Test func visibleUpdatesDoNotCreateAnUnreadBadge() {
        let model = DockModel()

        model.markPopoverVisible()
        model.markUnreadUpdate()

        #expect(!model.hasUnreadResponse)
    }

    @Test func commandCenterUpdatesBecomeUnreadAtTheGlobalBoundary() {
        let model = DockModel()
        model.markPopoverHidden()

        model.receiveGatewayEvent("background.complete", params: [
            "session_id": "another-session",
            "payload": ["task_id": "background-task", "text": "Finished"]
        ])

        #expect(model.hasUnreadResponse)
    }

    @Test func routineProgressDoesNotCreateAnUnreadBadge() {
        let model = DockModel()
        model.markPopoverHidden()

        model.receiveGatewayEvent("message.delta", params: [
            "session_id": "another-session",
            "payload": ["delta": "Still working"]
        ])

        #expect(!model.hasUnreadResponse)
    }

    @Test func approvalPanelPlaysASoundOnlyWhenFirstPresented() {
        var soundCount = 0
        let model = DockModel(approvalSoundPlayer: { soundCount += 1 }, initialSessionID: "session-approval")
        let event: [String: Any] = ["session_id": "session-approval", "payload": ["command": "git push"]]

        model.receiveGatewayEvent("approval.request", params: event)
        model.receiveGatewayEvent("approval.request", params: event)

        #expect(model.approvalText == "git push")
        #expect(soundCount == 1)
    }

    @Test func missingSessionsResponsePublishesFailedProjectionInsteadOfEmptySuccess() async {
        let client = SessionProjectionTestRPCClient(results: ["session.list": [.success([:])]])
        let model = DockModel(rpcClient: client)

        let task = model.loadSessions()
        await task?.value

        #expect(model.sessions.isEmpty)
        #expect(model.sessionProjectionState == .failed(safeMessage: "Hermes session data is unavailable. Try refreshing."))
    }

    @Test func nonArraySessionsResponseRetainsPriorProjectionAsStale() async {
        let validSession: [String: Any] = ["id": "session-1", "title": "Project"]
        let client = SessionProjectionTestRPCClient(results: [
            "session.list": [.success(["sessions": [validSession]]), .success(["sessions": "not-an-array"])]
        ])
        let model = DockModel(rpcClient: client)

        let initialTask = model.loadSessions()
        await initialTask?.value
        let previousSessions = model.sessions
        #expect(model.sessionProjectionState == .ready(previousSessions))

        let refreshTask = model.loadSessions()
        await refreshTask?.value

        #expect(model.sessionProjectionState == .stale(previousSessions, safeMessage: "Hermes session data is unavailable. Try refreshing."))
    }

    @Test func malformedRestoreResponsePreservesPersistedLastSessionID() async {
        let defaults = UserDefaults(suiteName: "projection-malformed-restore-\(UUID().uuidString)")!
        defaults.set("saved-session", forKey: "hermes.session.last-active.v1")
        let client = SessionProjectionTestRPCClient(results: [
            "session.resume": [.failure(.rejected)],
            "session.list": [.success(["sessions": NSNull()])]
        ])
        let model = DockModel(defaults: defaults, rpcClient: client)

        let task = model.restoreLatestSessionIfNeeded()
        await task?.value

        #expect(defaults.string(forKey: "hermes.session.last-active.v1") == "saved-session")
        #expect(model.sessionProjectionState == .failed(safeMessage: "Hermes session data is unavailable. Try refreshing."))
        #expect(model.messages.allSatisfy { !$0.text.contains("rejected") })
    }

    @Test func failedSessionListPublishesFailedProjectionInsteadOfEmptySuccess() async {
        let model = DockModel(rpcClient: InterruptTestRPCClient(result: .failure(.rejected)))

        let task = model.loadSessions()
        await task?.value

        #expect(model.sessions.isEmpty)
        #expect(model.sessionProjectionState == .failed(safeMessage: "Hermes session data is unavailable. Try refreshing."))
    }

    @Test func failedSessionRestorePublishesFailedProjection() async {
        let defaults = UserDefaults(suiteName: "projection-restore-\(UUID().uuidString)")!
        defaults.set("saved-session", forKey: "hermes.session.last-active.v1")
        let model = DockModel(defaults: defaults, rpcClient: InterruptTestRPCClient(result: .failure(.rejected)))

        let task = model.restoreLatestSessionIfNeeded()
        await task?.value

        #expect(model.sessionProjectionState == .failed(safeMessage: "Hermes session data is unavailable. Try refreshing."))
    }

    @Test func failedNewSessionCreationPublishesFailedProjection() async {
        let model = DockModel(rpcClient: InterruptTestRPCClient(result: .failure(.rejected)))

        await model.startNewChat(in: "/tmp/project")

        #expect(model.sessionProjectionState == .failed(safeMessage: "Hermes could not start a new session. Try again."))
    }

    @Test func unsupportedProjectionFailurePublishesUnavailableState() {
        let model = ControlCenterModel()

        model.recordProjectionFailure("sessions", error: "RPC method unsupported")

        #expect(model.projectionState(for: "sessions") == .unavailable(safeMessage: "Hermes projection is unavailable because this capability is not supported or authorized. Reconnect Hermes and retry."))
    }

    @Test func refreshWithoutBoundGatewayPublishesUnavailableProjection() {
        let model = ControlCenterModel()

        model.refresh()

        #expect(model.projectionState(for: "sessions") == .unavailable(safeMessage: "Hermes projection is unavailable because this capability is not supported or authorized. Reconnect Hermes and retry."))
        #expect(model.projectionState(for: "sessions") != .empty)
    }

    @Test func controlCenterProjectionStateDistinguishesFailureFromEmptySuccess() {
        let model = ControlCenterModel()

        #expect(model.projectionState(for: "sessions") == nil)
        model.recordProjectionSuccess("sessions", count: 0)
        #expect(model.projectionState(for: "sessions") == .empty)
        model.recordProjectionFailure("sessions", error: "token=secret-value")
        #expect(model.projectionState(for: "sessions") == .stale(0, safeMessage: "Hermes projection is unavailable. Refresh to try again."))
        #expect(model.refreshState(for: "sessions")?.error?.contains("secret-value") == false)
    }

    @Test func latestActivityFailureIsPublishedForTodayProjectionNotice() {
        let model = ControlCenterModel()

        model.recordProjectionFailure("latest.activity", error: "activity request failed")

        #expect(model.latestActivities.isEmpty)
        #expect(model.projectionState(for: "latest.activity") == .failed(safeMessage: "Hermes projection is unavailable. Refresh to try again."))
    }

    @Test func latestActivityAcceptsHermesNumericMessageIDs() {
        let steps = ControlCenterModel.parseActivityStepsEnvelope([
            "data": [["id": 1, "role": "assistant"]]
        ])

        #expect(steps?.count == 1)
        #expect(steps?.first?.id == "1-0")
    }

    @Test func latestActivityRefreshUsesHermesCompatibleSessionPageLimit() async {
        let client = LatestActivityProjectionRPCClient(
            pages: [
                ["data": [["id": "session-1", "title": "Project"]], "has_more": true],
                ["data": [["id": "session-2", "title": "Project"]], "has_more": false]
            ],
            messages: ["data": [["id": "activity-1", "role": "assistant"]]]
        )
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))

        model.refresh()
        for _ in 0..<20 { await Task.yield() }

        #expect(model.latestActivities.count == 2)
        #expect(client.sessionPagePaths == [
            "/api/sessions?limit=100&offset=0",
            "/api/sessions?limit=100&offset=1"
        ])
    }

    @Test func emptyPageWithMoreResultsRetainsPriorActivityAndPublishesStaleFailure() async {
        let client = LatestActivityProjectionRPCClient(
            pages: [
                ["data": [["id": "session-1", "title": "Project"]], "has_more": false],
                ["data": [], "has_more": true]
            ],
            messages: ["data": [["id": "activity-1", "role": "assistant"]]]
        )
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))

        model.refresh()
        for _ in 0..<20 { await Task.yield() }
        let previousActivities = model.latestActivities
        #expect(!previousActivities.isEmpty)

        model.refresh()
        for _ in 0..<20 { await Task.yield() }

        #expect(model.latestActivities == previousActivities)
        let isStale: Bool
        if case .stale = model.projectionState(for: "latest.activity") {
            isStale = true
        } else {
            isStale = false
        }
        #expect(isStale)
    }

    @Test func clientRebindClearsRetainedActivityProjectionState() {
        let oldClient = LatestActivityProjectionRPCClient(
            pages: [],
            messages: ["data": []]
        )
        let newClient = LatestActivityProjectionRPCClient(
            pages: [],
            messages: ["data": []]
        )
        let oldDock = DockModel(rpcClient: oldClient)
        let newDock = DockModel(rpcClient: newClient)
        let model = ControlCenterModel()

        model.recordProjectionSuccess("latest.activity", count: 2)
        #expect(model.projectionState(for: "latest.activity") == .ready(2))

        let projectionNames = ["reminders", "cron.jobs", "sessions", "latest.activity", "agents", "processes", "projects"]
        for projection in projectionNames {
            model.recordProjectionSuccess(projection, count: 2)
        }

        model.bind(to: oldDock)
        for projection in projectionNames {
            #expect(model.projectionState(for: projection) == nil)
            #expect(model.refreshState(for: projection) == nil)
        }
        #expect(model.latestActivities.isEmpty)

        model.recordProjectionSuccess("latest.activity", count: 1)
        model.bind(to: newDock)
        for projection in projectionNames {
            #expect(model.projectionState(for: projection) == nil)
            #expect(model.refreshState(for: projection) == nil)
        }
        #expect(model.latestActivities.isEmpty)
    }


    @Test func kanbanStderrIsSanitizedBeforeBecomingLastError() {
        let diagnostic = ControlCenterModel.safeUserDiagnostic("token=secret-value at /Users/christian/private")

        #expect(!diagnostic.contains("secret-value"))
        #expect(!diagnostic.contains("/Users/christian/private"))
    }
}
