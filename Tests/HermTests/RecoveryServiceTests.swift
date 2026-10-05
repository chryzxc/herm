import Testing
@testable import Herm

struct RecoveryServiceTests {
    @Test func parsesOnlyStructuredReadinessForAllRecoveryFeatures() {
        let snapshot = RecoveryService.snapshot(from: [
            "backup": ["supported": true, "ready": true, "detail": "Backup status available."],
            "import": ["supported": true, "ready": false, "detail": "Select a source."],
            "import_agent": ["supported": false],
            "migration": ["supported": true, "ready": true],
            "sync": ["supported": true, "ready": false],
            "openclaw_migration": ["supported": false],
            "update": ["supported": true, "ready": true, "detail": "Update check available."]
        ])

        #expect(snapshot.items.map(\.id) == RecoveryFeature.allCases)
        #expect(snapshot.item(.backup)?.state == .requiresConfirmation)
        #expect(snapshot.item(.import)?.state == .requiresConfirmation)
        #expect(snapshot.item(.importAgent)?.state == .unsupported)
        #expect(snapshot.item(.migration)?.state == .requiresConfirmation)
        #expect(snapshot.item(.sync)?.state == .requiresConfirmation)
        #expect(snapshot.item(.openClawMigration)?.state == .unsupported)
        #expect(snapshot.item(.update)?.state == .ready)
    }

    @Test func missingOrMalformedPayloadFailsClosed() {
        let snapshot = RecoveryService.snapshot(from: [
            "backup": ["ready": true],
            "migration": "not structured"
        ])

        #expect(snapshot.item(.backup)?.state == .unavailable)
        #expect(snapshot.item(.migration)?.state == .unavailable)
        #expect(snapshot.item(.update)?.state == .unavailable)
    }

    @Test func consequentialOperationsRemainUnavailableEvenWhenConfirmed() {
        let snapshot = RecoveryService.snapshot(from: [
            "backup": ["supported": true, "ready": true]
        ])

        for feature in RecoveryFeature.allCases where feature.isConsequential {
            #expect(RecoveryService.requestMutation(feature, snapshot: snapshot, confirmed: false) == .confirmationRequired)
            #expect(RecoveryService.requestMutation(feature, snapshot: snapshot, confirmed: true) == .unavailable)
        }
    }

    @Test func unsafeDetailAndPathsAreNotRetained() {
        let snapshot = RecoveryService.snapshot(from: [
            "backup": ["supported": true, "ready": true, "detail": "/Users/example/.hermes/token=secret"]
        ])

        #expect(snapshot.item(.backup)?.detail == "Ready to review; no action is enabled.")
        #expect(!snapshot.items.contains { $0.detail.contains("example") || $0.detail.contains("secret") })
    }
}
