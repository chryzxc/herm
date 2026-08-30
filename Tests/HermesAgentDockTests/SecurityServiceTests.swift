import Foundation
import Testing
@testable import HermesAgentDock

struct SecurityServiceTests {
    private let validJSON = #"{"schema":"hermes.security.control-plane.v1","approvals":{"state":"ready","pending":2},"safeMode":{"state":"enabled","reason":"policy"},"checkpoints":{"state":"ready","count":3},"secretSources":{"state":"ready","sources":[{"id":"env","kind":"environment","present":true}]},"egress":{"state":"ready","network":"restricted","allowlistedHosts":1},"doctor":{"state":"ready","checks":4,"failures":0},"security":{"state":"ready","score":"good"},"logs":{"state":"ready","events":2}}"#

    @Test func parsesEveryReadOnlyProjection() throws {
        let snapshot = try SecurityService.parseVerifiedJSON(validJSON)
        #expect(snapshot.state == .ready)
        #expect(snapshot.approvals.pending == 2)
        #expect(snapshot.safeMode.state == "enabled")
        #expect(snapshot.checkpoints.count == 3)
        #expect(snapshot.secretSources.sources[0].kind == "environment")
        #expect(snapshot.egress.allowlistedHosts == 1)
        #expect(snapshot.doctor.failures == 0)
        #expect(snapshot.security.score == "good")
        #expect(snapshot.logs.events == 2)
    }

    @Test func malformedOrUnsupportedOutputFailsClosed() {
        #expect(SecurityService.parse("not json", format: .json).state == .malformed)
        #expect(SecurityService.parse("{}", format: .human).state == .unsupported)
        #expect(SecurityService.unavailable().state == .unavailable)
    }

    @Test func secretBearingPayloadNeverEntersDurableModels() {
        let secret = #"{"schema":"hermes.security.control-plane.v1","approvals":{"state":"ready","pending":0},"safeMode":{"state":"enabled","reason":"token=abc"},"checkpoints":{"state":"ready","count":0},"secretSources":{"state":"ready","sources":[{"id":"/Users/me/key","kind":"api_key=ghp_secret","present":true}]},"egress":{"state":"ready","network":"Bearer abc","allowlistedHosts":0},"doctor":{"state":"ready","checks":0,"failures":0},"security":{"state":"ready","score":"/private/log"},"logs":{"state":"ready","events":0}}"#
        let result = SecurityService.parse(secret, format: .json)
        #expect(result.state == .malformed)
        #expect(!String(describing: result).contains("ghp_secret"))
        #expect(!String(describing: result).contains("/Users"))
    }

    @Test func unsupportedActionsAreUnavailableBeforeConfirmation() {
        #expect(SecurityService.perform(.refresh, confirmed: false) == .unavailable)
        #expect(SecurityService.perform(.refresh, confirmed: true) == .unavailable)
        #expect(SecurityService.perform(.copyRecoveryInstructions, confirmed: true) == .unavailable)
        #expect(SecurityService.perform(.deleteCheckpoint, confirmed: true) == .unavailable)
        #expect(!SecurityService.availableActions.contains(.refresh))
        #expect(!SecurityService.availableActions.contains(.deleteCheckpoint))
    }

    @Test func confirmedActionsWithoutVerifiedAdaptersFailClosed() {
        #expect(SecurityService.perform(.refresh, confirmed: true) == .unavailable)
        #expect(SecurityService.perform(.copyRecoveryInstructions, confirmed: true) == .unavailable)
        #expect(!SecurityService.availableActions.contains(.refresh))
        #expect(!SecurityService.availableActions.contains(.copyRecoveryInstructions))
    }
}
