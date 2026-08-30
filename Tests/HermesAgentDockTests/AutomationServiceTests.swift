import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct AutomationServiceTests {
    @Test func parsesDistinctAutomationEntitiesOnlyFromStructuredEnvelopes() throws {
        let snapshot = try AutomationService.parseSnapshot([
            "cron": ["jobs": [["id": "c1", "name": "Nightly", "schedule": "30m", "enabled": true, "skills": ["review"], "model": "gpt-5"]]],
            "kanban": ["tasks": [["id": "k1", "title": "Ship", "status": "ready"]]],
            "goals": ["goals": [["id": "g1", "title": "Goal", "status": "active"]]],
            "loops": ["loops": [["id": "l1", "name": "Loop", "status": "running"]]],
            "heartbeats": ["heartbeats": [["id": "h1", "status": "healthy", "last_seen": "2026-08-29T00:00:00Z"]]]
        ])

        #expect(snapshot.cron.count == 1)
        #expect(snapshot.cron[0].skills == ["review"])
        #expect(snapshot.kanban.count == 1)
        #expect(snapshot.goals[0].id == "g1")
        #expect(snapshot.loops[0].id == "l1")
        #expect(snapshot.heartbeats[0].lastSeen == "2026-08-29T00:00:00Z")
    }

    @Test func malformedOrMissingEntityEnvelopeIsUnavailableNotEmptySuccess() {
        #expect(AutomationService.parseGoals(["data": "not-an-array"]) == nil)
        #expect(AutomationService.parseLoops([:]) == nil)
        #expect(AutomationService.parseHeartbeats(["heartbeats": [["id": ""]]]) == nil)
    }

    @Test func operationCapabilitiesAreDistinctAndFailClosed() {
        let gate = AutomationCapabilityGate(available: ["cron.create", "cron.run", "kanban.pause"])
        #expect(gate.allows(.createCron))
        #expect(gate.allows(.runCron))
        #expect(gate.allows(.pauseKanban))
        #expect(!gate.allows(.deleteCron))
        #expect(!gate.allows(.resumeGoal))
    }

    @Test func operationRequestUsesTypedFieldsAndPreservesScheduleGrammar() {
        let request = AutomationOperationRequest.createCron(name: "interval", schedule: "every 2h", prompt: "check")
        #expect(request.capabilityID == "cron.create")
        #expect(request.parameters["schedule"] as? String == "every 2h")
        #expect(request.parameters["name"] as? String == "interval")
    }

    @Test func unavailableProjectionExplainsUnsupportedAutomationWithoutClaimingSupport() {
        let state = AutomationProjectionState.unavailable(.unsupported("Hermes 0.20.6 exposes no structured goals command."))
        #expect(state.isUnavailable)
        #expect(state.message.contains("no structured goals command"))
    }
}
