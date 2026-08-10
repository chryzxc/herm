import Foundation
import Testing
@testable import HermesAgentDock

struct CapabilityStateTests {
    @Test func recoveryCommandIsOptionalMetadata() {
        let state = CapabilityState(id: "gateway", title: "Gateway", detail: "Offline", isAvailable: false, recovery: "Start Hermes", recoveryCommand: "hermes gateway start")

        #expect(state.recoveryCommand == "hermes gateway start")
        #expect(state.availability == .unsupported)
        #expect(state.source == .gateway)
    }

    @Test func capabilitySnapshotLooksUpStableIDs() {
        let snapshot = CapabilitySnapshot(states: [
            CapabilityState(id: "kanban.taskDetails", title: "Details", detail: "Available", isAvailable: true, recovery: nil, source: .cli)
        ], generatedAt: Date())

        #expect(snapshot.state(for: "kanban.taskDetails")?.isAvailable == true)
        #expect(snapshot.state(for: "missing") == nil)
    }

    @Test func inboxFiltersPreserveCategoryMembership() {
        let approval = AttentionItem(id: "approval:1", reference: ControlReference(source: .hermesApproval, sourceID: "1"), kind: .approval, title: "Approve", detail: "", createdAt: .now, state: .open, actions: [])
        let failure = AttentionItem(id: "failure:1", reference: ControlReference(source: .hermesSession, sourceID: "1"), kind: .failure, title: "Failed", detail: "", createdAt: .now, state: .open, actions: [])

        #expect(InboxFilter.needsResponse.includes(approval))
        #expect(!InboxFilter.needsResponse.includes(failure))
        #expect(InboxFilter.failures.includes(failure))
    }
}
