import Testing

@testable import Herm

struct ControlTowerNotificationPolicyTests {
    @Test func deduplicatesAttentionAndUsesGenericPayloads() {
        let item = AttentionItem(
            id: "a", reference: ControlReference(source: .hermesApproval, sourceID: "a"), kind: .approval,
            title: "secret prompt", detail: "raw output should not leak", createdAt: .now, state: .open,
            actions: [.approve])
        let first = ControlTowerNotificationPolicy.newlyNotifiableAttention([item], previouslyNotified: [])
        #expect(first.count == 1)
        #expect(first[0].body.contains("raw output") == false)
        #expect(
            ControlTowerNotificationPolicy.newlyNotifiableAttention([item], previouslyNotified: Set(first.map(\.id)))
                .isEmpty)
    }

    @Test func terminalStateAndCapabilityEventsAreSuppressedAfterFirstObservation() {
        let result = ControlTowerNotificationPolicy.terminalBackgroundResult(
            id: "task", succeeded: false, previouslyNotified: [])!
        #expect(result.title == "Background task failed")
        #expect(
            ControlTowerNotificationPolicy.terminalBackgroundResult(
                id: "task", succeeded: false, previouslyNotified: [result.id]) == nil)
        let degraded = ControlTowerNotificationPolicy.capabilityDegraded(
            id: "mcp", available: false, previouslyNotified: [])!
        #expect(degraded.body.contains("unavailable"))
        #expect(
            ControlTowerNotificationPolicy.capabilityDegraded(id: "mcp", available: true, previouslyNotified: []) == nil
        )
    }
}
