import Testing
@testable import HermesAgentDock

@MainActor
struct HermesProjectionStateTests {
    @Test func representsLoadingAndEmptyStates() {
        let loading = HermesProjectionState<Int>.loading
        let empty = HermesProjectionState<Int>.empty

        #expect(loading == .loading)
        #expect(empty == .empty)
    }

    @Test func representsReadyValue() {
        let state = HermesProjectionState.ready(["gateway", "tools"])

        #expect(state == .ready(["gateway", "tools"]))
    }

    @Test func representsStaleValueWithSafeMessage() {
        let message = "Showing the last successful snapshot. Refresh to try again."
        let state = HermesProjectionState.stale(42, safeMessage: message)

        #expect(state == .stale(42, safeMessage: message))
    }

    @Test func representsUnavailableWithSafeMessage() {
        let message = "Capability inspection is unavailable. Reconnect Hermes and refresh."
        let state = HermesProjectionState<Int>.unavailable(safeMessage: message)

        #expect(state == .unavailable(safeMessage: message))
    }

    @Test func representsFailedWithSafeMessage() {
        let message = "Capability inspection failed. Try refreshing."
        let state = HermesProjectionState<Int>.failed(safeMessage: message)

        #expect(state == .failed(safeMessage: message))
    }

    @Test func preservesDistinctValuesAndMessagesForEquatableComparisons() {
        let message = "The cached result is stale."

        #expect(HermesProjectionState.ready(1) != .ready(2))
        #expect(HermesProjectionState.stale(1, safeMessage: message) != .stale(1, safeMessage: "Try again."))
        #expect(HermesProjectionState<Int>.unavailable(safeMessage: message) != .failed(safeMessage: message))
    }

    @Test func failedSessionRefreshRetainsTheLastSuccessfulProjection() {
        let previous = HermesProjectionState.ready([
            HermesSession(id: "session-1", title: "Project", preview: "Preview", startedAt: nil, messageCount: 1, source: "hermes")
        ])
        let loading = HermesProjectionState<[HermesSession]>.loading

        #expect(loading == .loading)
        #expect(DockModel.failedOrStale(previous, safeMessage: "Refresh failed.") == .stale(previousValue(previous), safeMessage: "Refresh failed."))
    }

    @Test func failedRuntimeInspectionRetainsTheLastSuccessfulConfiguration() {
        let previous = HermesRuntimeConfiguration(
            agentName: nil,
            model: "gpt-5",
            provider: "openai",
            configPath: "/tmp/config.yaml",
            maxTurns: "10",
            terminalTimeout: "30",
            skills: ["hermes-agent"],
            skillsInventory: .supported(["hermes-agent"]),
            mcpServers: ["local"],
            plugins: ["review"]
        )
        let loading = HermesProjectionState<HermesRuntimeConfiguration>.loading

        #expect(loading == .loading)
        #expect(DockModel.failedOrStale(.ready(previous), safeMessage: "Inspection failed.") == .stale(previous, safeMessage: "Inspection failed."))
    }

    @Test func userVisibleDiagnosticsAreSanitizedAtControlCenterBoundary() {
        let raw = "failed at /Users/christian/.hermes/config.yaml token=super-secret"
        let safe = ControlCenterModel.safeUserDiagnostic(raw)
        #expect(!safe.contains("/Users/christian"))
        #expect(!safe.contains("super-secret"))
    }

    @Test func userVisibleDiagnosticsAreSanitizedAtDockBoundary() {
        let raw = "failed at /Users/christian/.hermes/config.yaml token=super-secret"
        let safe = DockModel.safeUserDiagnostic(raw)
        #expect(!safe.contains("/Users/christian"))
        #expect(!safe.contains("super-secret"))
    }

    @Test func activityEnvelopeRequiresAuthoritativeDataArray() {
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["messages": [["role": "assistant"]]]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": "not-an-array", "messages": [["role": "assistant"]]]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope([
            "data": [["role": "assistant"]],
            "messages": [["role": "user"]]
        ]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": []]) == [])
    }

    @Test func malformedActivityEnvelopeIsNotParsedAsAnEmptySuccess() {
        #expect(ControlCenterModel.parseActivityStepsEnvelope([:]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": "not-an-array"]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [["role": "assistant"]]]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": []]) == [])
    }

    @Test func missingActivityIDRejectsTheWholePageIncludingMixedRows() {
        let valid: [String: Any] = ["id": "activity-1", "role": "assistant"]
        let missing: [String: Any] = ["role": "tool", "tool_name": "read_file"]

        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [missing]]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [valid, missing]]) == nil)
    }

    @Test func duplicateActivityIDsRejectTheWholePageIncludingMixedRows() {
        let first: [String: Any] = ["id": "activity-1", "role": "assistant"]
        let duplicate: [String: Any] = ["id": "activity-1", "role": "tool", "tool_name": "read_file"]
        let distinct: [String: Any] = ["id": "activity-2", "role": "assistant"]

        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [first, duplicate]]) == nil)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [first, duplicate, distinct]]) == nil)
    }

    @Test func malformedSessionRowsRejectTheEntireSessionProjection() {
        #expect(ControlCenterModel.parseSessions(["data": [
            ["id": "session-1", "title": "Valid"],
            ["id": 42, "title": "Malformed"]
        ]]) == nil)
    }

    @Test func malformedActivityRowFieldsRejectTheEntireActivityProjection() {
        let malformedRows: [[String: Any]] = [
            ["role": 42],
            ["id": ["not-an-id"]],
            ["timestamp": "not-a-date"],
            ["tool_calls": ["not-a-call"]],
            ["tool_calls": [["function": "not-an-object"]]],
            ["tool_calls": [["name": 42]]]
        ]

        for row in malformedRows {
            #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [row]]) == nil)
        }
    }

    @Test func malformedOrMissingHasMoreIsRejected() {
        #expect(ControlCenterModel.parseHasMore(["has_more": "true"]) == nil)
        #expect(ControlCenterModel.parseHasMore(["has_more": 1]) == nil)
        #expect(ControlCenterModel.parseHasMore([:]) == nil)
        #expect(ControlCenterModel.parseHasMore(["has_more": true]) == true)
    }

    @Test func sessionAndActivityIdentifiersMustBeNonEmptyButValidValuesRemainExact() {
        for invalidID in ["", " ", "\n\t"] {
            #expect(ControlCenterModel.parseSessions(["data": [["id": invalidID, "title": "Invalid"]]]) == nil)
            #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [["id": invalidID, "role": "assistant"]]]) == nil)
        }

        let sessionID = "  session-exact  "
        let activityID = "  activity-exact  "
        #expect(ControlCenterModel.parseSessions(["data": [["id": sessionID, "title": "Valid"]]])?.first?.id == sessionID)
        #expect(ControlCenterModel.parseActivityStepsEnvelope(["data": [["id": activityID, "role": "assistant"]]])?.first?.id == "\(activityID)-0")
    }

    @Test func repeatedPaginationPagesAreRejected() {
        let page = [["id": "session-1", "title": "One"]] as [[String: Any]]
        var seenSignatures = Set<String>()
        var seenSessionIDs = Set<String>()
        #expect(!ControlCenterModel.paginationPageIsRepeated(page, seenSignatures: &seenSignatures, seenSessionIDs: &seenSessionIDs))
        #expect(ControlCenterModel.paginationPageIsRepeated(page, seenSignatures: &seenSignatures, seenSessionIDs: &seenSessionIDs))
    }

    @Test func paginationPagesWithOverlappingSessionIDsAreRejected() {
        let first = [["id": "session-1", "title": "One"], ["id": "session-2", "title": "Two"]] as [[String: Any]]
        let overlapping = [["id": "session-2", "title": "Two updated"], ["id": "session-3", "title": "Three"]] as [[String: Any]]
        var seenSignatures = Set<String>()
        var seenSessionIDs = Set<String>()

        #expect(!ControlCenterModel.paginationPageIsRepeated(first, seenSignatures: &seenSignatures, seenSessionIDs: &seenSessionIDs))
        #expect(ControlCenterModel.paginationPageIsRepeated(overlapping, seenSignatures: &seenSignatures, seenSessionIDs: &seenSessionIDs))
    }

    private func previousValue<Value>(_ state: HermesProjectionState<[Value]>) -> [Value] {
        guard case .ready(let value) = state else { return [] }
        return value
    }
}
