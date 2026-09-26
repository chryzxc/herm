import Foundation
import Testing
@testable import Herm

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

    @Test func readinessMetadataDistinguishesConfiguredButUnverifiedCapability() {
        let state = CapabilityState(
            id: "ocr",
            title: "OCR",
            detail: "Configured locally",
            isAvailable: true,
            recovery: nil,
            source: .local,
            category: .review,
            provenance: .localTool,
            probeState: .unverified,
            accessClassification: .safeReadOnly
        )

        #expect(state.category == .review)
        #expect(state.provenance == .localTool)
        #expect(state.probeState == .unverified)
        #expect(state.accessClassification == .safeReadOnly)
        #expect(state.isAvailable)
    }

    @Test func readinessMetadataRepresentsMissingAndUnsupportedCapabilities() {
        let missing = CapabilityState(
            id: "gitleaks",
            title: "Gitleaks",
            detail: "Not installed",
            isAvailable: false,
            recovery: nil,
            availability: .unavailable,
            category: .security,
            provenance: .localTool,
            probeState: .missing,
            accessClassification: .safeReadOnly
        )
        let unsupported = CapabilityState(
            id: "mcp.launch",
            title: "MCP launch",
            detail: "Not supported by Dock",
            isAvailable: false,
            recovery: nil,
            category: .integration,
            provenance: .external,
            probeState: .unsupported,
            accessClassification: .externalSetup
        )

        #expect(missing.probeState == .missing)
        #expect(unsupported.probeState == .unsupported)
        #expect(!missing.isAvailable)
        #expect(!unsupported.isAvailable)
    }

    @Test func contradictoryMetadataIsNormalizedToTheLegacyAuthoritativeFields() {
        let state = CapabilityState(
            id: "external-review",
            title: "External review",
            detail: "Available",
            isAvailable: true,
            recovery: nil,
            source: .external,
            access: .externalSetup,
            availability: .unsupported,
            category: .core,
            provenance: .hermesGateway,
            probeState: .missing,
            accessClassification: .safeReadOnly
        )

        #expect(state.availability == .available)
        #expect(state.provenance == .external)
        #expect(state.accessClassification == .externalSetup)
        #expect(state.probeState == .unverified)
        #expect(state.isAvailable)
    }

    @Test func unavailableCapabilityCannotRemainVerifiedOrAvailable() {
        let state = CapabilityState(
            id: "security-check",
            title: "Security check",
            detail: "Missing",
            isAvailable: false,
            recovery: nil,
            source: .local,
            access: .readOnly,
            availability: .available,
            probeState: .verified
        )

        #expect(state.availability != .available)
        #expect(state.probeState != .verified)
        #expect(!state.isAvailable)
    }

    @Test func unsupportedAvailabilityAlwaysNormalizesProbeStateToUnsupported() {
        let state = CapabilityState(id: "unsupported", title: "Unsupported", detail: "", isAvailable: false, recovery: nil, availability: .unsupported, probeState: .missing)
        #expect(state.availability == .unsupported)
        #expect(state.probeState == .unsupported)
    }

    @Test func unavailableAvailabilityAlwaysNormalizesProbeStateToMissing() {
        let state = CapabilityState(id: "unavailable", title: "Unavailable", detail: "", isAvailable: false, recovery: nil, availability: .unavailable, probeState: .unsupported)
        #expect(state.availability == .unavailable)
        #expect(state.probeState == .missing)
    }

    @Test func sourceAndAccessAreAuthoritativeForCompatibilityMetadata() {
        let state = CapabilityState(id: "metadata", title: "Metadata", detail: "", isAvailable: true, recovery: nil, source: .cli, access: .confirmedMutation, provenance: .localTool, accessClassification: .safeReadOnly)
        #expect(state.provenance == .hermesCLI)
        #expect(state.accessClassification == .confirmedMutation)
    }

    @Test func omittedCategoryUsesDeterministicReadinessTaxonomy() {
        #expect(CapabilityState(id: "kanban.create", title: "Create", detail: "", isAvailable: true, recovery: nil).category == .integration)
        #expect(CapabilityState(id: "security.gitleaks", title: "Gitleaks", detail: "", isAvailable: false, recovery: nil).category == .security)
        #expect(CapabilityState(id: "code-review.ocr", title: "OCR", detail: "", isAvailable: true, recovery: nil).category == .review)
    }

    @Test func capabilityReadinessSortsAndGroupsDeterministically() {
        let states = [
            CapabilityState(id: "semgrep", title: "Semgrep", detail: "", isAvailable: true, recovery: nil, category: .security),
            CapabilityState(id: "gateway", title: "Gateway", detail: "", isAvailable: true, recovery: nil, category: .core),
            CapabilityState(id: "ocr", title: "OCR", detail: "", isAvailable: true, recovery: nil, category: .review),
            CapabilityState(id: "hermes", title: "Hermes", detail: "", isAvailable: true, recovery: nil, category: .core)
        ]
        let snapshot = CapabilitySnapshot(states: states, generatedAt: .now)

        #expect(snapshot.sortedStates.map(\.id) == ["gateway", "hermes", "ocr", "semgrep"])
        #expect(snapshot.statesByCategory[.core]?.map(\.id) == ["gateway", "hermes"])
        #expect(snapshot.statesByCategory[.security]?.map(\.id) == ["semgrep"])
    }

    @Test func inboxFiltersPreserveCategoryMembership() {
        let approval = AttentionItem(id: "approval:1", reference: ControlReference(source: .hermesApproval, sourceID: "1"), kind: .approval, title: "Approve", detail: "", createdAt: .now, state: .open, actions: [])
        let failure = AttentionItem(id: "failure:1", reference: ControlReference(source: .hermesSession, sourceID: "1"), kind: .failure, title: "Failed", detail: "", createdAt: .now, state: .open, actions: [])

        #expect(InboxFilter.needsResponse.includes(approval))
        #expect(!InboxFilter.needsResponse.includes(failure))
        #expect(InboxFilter.failures.includes(failure))
    }
}
