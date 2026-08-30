import Testing
@testable import HermesAgentDock

@MainActor
struct OperationsStatusTests {
    @Test func failedRefreshKeepsLastSnapshotAndMarksCardsStale() {
        let snapshot = OperationsStatusSnapshot(cards: [
            OperationsStatusCard(id: "gateway", title: "Gateway server", status: .running, detail: "Listening", formatSupport: .structured)
        ])
        var projection = OperationsStatusProjection(snapshot: snapshot)

        projection.beginRefresh()
        projection.failRefresh(message: "Refresh unavailable.")

        #expect(projection.state == .stale(snapshot, safeMessage: "Refresh unavailable."))
        #expect(projection.displayCards.first?.isStale == true)
    }

    @Test func successfulEmptyRefreshReplacesPriorSnapshot() {
        let previous = OperationsStatusSnapshot(cards: [
            OperationsStatusCard(id: "logs", title: "Logs", status: .ready, detail: "Available", formatSupport: .structured)
        ])
        var projection = OperationsStatusProjection(snapshot: previous)

        projection.beginRefresh()
        projection.succeed(with: OperationsStatusSnapshot(cards: []))

        #expect(projection.state == .ready(OperationsStatusSnapshot(cards: [])))
        #expect(projection.displayCards.isEmpty)
    }

    @Test func humanReadableSurfaceIsExplicitlyFormatUnsupported() {
        let card = OperationsStatusCard(
            id: "monitoring",
            title: "Monitoring",
            status: .ready,
            detail: "Human-readable output is display-only.",
            formatSupport: .humanReadable
        )

        #expect(card.formatNotice == "Structured status is unavailable; human-readable output is display-only.")
        #expect(card.isFormatUnsupported)
    }

    @Test func staleCompletionFromOlderGenerationCannotOverwriteNewerSnapshot() {
        var projection = OperationsStatusProjection()
        let first = projection.beginRefresh()
        let second = projection.beginRefresh()
        let newer = OperationsStatusSnapshot(cards: [
            OperationsStatusCard(id: "api", title: "API server", status: .ready, detail: "Available", formatSupport: .structured)
        ])

        let accepted = projection.succeed(with: newer, generation: second)
        let rejected = projection.succeed(with: OperationsStatusSnapshot(cards: []), generation: first)
        #expect(accepted)
        #expect(!rejected)
        #expect(projection.displayCards.map(\.id) == ["api"])
    }

    @Test func startAndStopRequireConfirmationIdentityAndReadBack() {
        let identity = OperationsProcessIdentity(kind: .gatewayServer, instanceID: "gateway-1")
        let request = OperationsControlRequest(action: .start, identity: identity, timeout: .seconds(5), confirmed: true)

        #expect(OperationsControlGate.validate(request: request, observed: nil) == .awaitingReadBack)
        #expect(OperationsControlGate.validate(request: request, observed: identity) == .accepted)
        #expect(OperationsControlGate.validate(request: request, observed: OperationsProcessIdentity(kind: .gatewayServer, instanceID: "other")) == .identityMismatch)
        #expect(OperationsControlGate.validate(request: OperationsControlRequest(action: .stop, identity: identity, timeout: .seconds(5), confirmed: false), observed: identity) == .confirmationRequired)
    }
}
