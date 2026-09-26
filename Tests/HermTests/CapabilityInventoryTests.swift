import Foundation
import Testing
@testable import Herm

@MainActor
struct CapabilityInventoryTests {
    @Test func projectsCategoriesCountsAndStableOrdering() {
        let model = ControlCenterModel(capabilities: [
            CapabilityState(id: "security.zeta", title: "Zeta", detail: "", isAvailable: false, recovery: nil, availability: .unavailable, category: .security),
            CapabilityState(id: "core.beta", title: "Beta", detail: "", isAvailable: true, recovery: nil, category: .core, probeState: .verified),
            CapabilityState(id: "integration.alpha", title: "Alpha", detail: "", isAvailable: true, recovery: nil, category: .integration, probeState: .unverified),
            CapabilityState(id: "core.alpha", title: "Alpha", detail: "", isAvailable: false, recovery: nil, availability: .unsupported, category: .core),
            CapabilityState(id: "review.gamma", title: "Gamma", detail: "", isAvailable: false, recovery: nil, availability: .unavailable, category: .review)
        ])

        let snapshot = model.capabilitySnapshot

        #expect(snapshot.totalCount == 5)
        #expect(snapshot.availableCount == 2)
        #expect(snapshot.verifiedCount == 1)
        #expect(snapshot.unverifiedCount == 1)
        #expect(snapshot.missingCount == 2)
        #expect(snapshot.unsupportedCount == 1)
        #expect(CapabilityCategory.allCases.compactMap { snapshot.statesByCategory[$0]?.map(\.id) } == [
            ["core.alpha", "core.beta"], ["integration.alpha"], ["review.gamma"], ["security.zeta"]
        ])
        #expect(snapshot.sortedStates.map(\.id) == ["core.alpha", "core.beta", "integration.alpha", "review.gamma", "security.zeta"])
    }

    @Test func capabilitySnapshotKeepsPublicationTimestampStableUntilRefresh() {
        let model = ControlCenterModel(capabilities: [
            CapabilityState(id: "core.hermes", title: "Hermes", detail: "", isAvailable: true, recovery: nil, category: .core)
        ])

        let firstRead = model.capabilitySnapshot
        Thread.sleep(forTimeInterval: 0.01)
        let secondRead = model.capabilitySnapshot

        #expect(secondRead.generatedAt == firstRead.generatedAt)
        #expect(secondRead == firstRead)
    }

    @Test func projectsEmptyCapabilitiesWithoutCategoriesOrCounts() {
        let model = ControlCenterModel()
        let snapshot = model.capabilitySnapshot

        #expect(snapshot.states.isEmpty)
        #expect(snapshot.totalCount == 0)
        #expect(snapshot.availableCount == 0)
        #expect(snapshot.verifiedCount == 0)
        #expect(snapshot.unverifiedCount == 0)
        #expect(snapshot.missingCount == 0)
        #expect(snapshot.unsupportedCount == 0)
        #expect(snapshot.sortedStates.isEmpty)
        #expect(snapshot.statesByCategory.isEmpty)
    }
}
