import Foundation
import Testing
@testable import Herm

struct ProfileServiceTests {
    @Test func parsesIsolatedProfilesAndConnectionsFromStrictJSON() throws {
        let json = #"{"profiles":[{"name":"default","model":"gpt-5.6-terra","gateway":"running"},{"name":"work","model":"claude","gateway":"unavailable"}],"connections":[{"profile":"default","status":"ready"},{"profile":"work","status":"unavailable"}]}"#

        let result = try HermesProfileService.parseVerifiedJSON(json)

        #expect(result.state == .ready)
        #expect(result.profiles.map(\.name) == ["default", "work"])
        #expect(result.profiles[0].model == "gpt-5.6-terra")
        #expect(result.connections.map(\.profileName) == ["default", "work"])
        #expect(result.connections[1].state == .unavailable)
    }

    @Test func remoteUnavailableIsExplicitAndContainsNoEndpointDetails() {
        let result = HermesProfileService.unavailable(reason: "remote gateway unavailable")

        #expect(result.state == .unavailable)
        #expect(result.profiles.isEmpty)
        #expect(result.connections.isEmpty)
        #expect(result.diagnostic == "Inventory is unavailable.")
        #expect(!result.diagnostic.contains("http"))
        #expect(!result.diagnostic.contains("token"))
    }

    @Test func unavailableDiagnosticsNeverPreserveUntrustedReasonText() {
        let hostileReasons = [
            "password=hunter2",
            "secret=top-secret",
            "api_key=sk-live-123",
            "Authorization: Bearer abc.def.ghi",
            "file:///Users/example/Projects/private",
            "ssh://user@example.com/var/lib/hermes",
            "gateway failed at /Users/example/.config/hermes/config.yaml",
            "gateway failed for https://user:token@example.com/api"
        ]

        for reason in hostileReasons {
            let result = HermesProfileService.unavailable(reason: reason)

            #expect(result.diagnostic == "Inventory is unavailable.")
            #expect(!result.diagnostic.contains(reason))
        }
    }

    @Test func malformedResponseDoesNotPartiallyParseOrRetainRawPayload() {
        let result = HermesProfileService.parse("{\"profiles\":[{\"name\":\"default\"}]", format: .json)

        #expect(result.state == .malformed)
        #expect(result.profiles.isEmpty)
        #expect(result.connections.isEmpty)
        #expect(!result.diagnostic.contains("default"))
    }

    @Test func humanTablesAreUnsupportedRatherThanGuessed() {
        let table = "Profile Model Gateway Alias\n◆default gpt-5.6-terra running —"

        let result = HermesProfileService.parse(table, format: .humanTable)

        #expect(result.state == .unsupported)
        #expect(result.profiles.isEmpty)
        #expect(result.connections.isEmpty)
    }

    @Test func staleDataIsExplicitWhenSnapshotAgeExceedsPolicy() throws {
        let json = #"{"profiles":[{"name":"default","model":"gpt-5.6-terra","gateway":"running"}],"connections":[]}"#
        let old = Date(timeIntervalSince1970: 100)
        let result = try HermesProfileService.parseVerifiedJSON(json, observedAt: old, now: Date(timeIntervalSince1970: 120), maxAge: 10)

        #expect(result.state == .stale)
        #expect(result.profiles.count == 1)
        #expect(result.connections.isEmpty)
    }

    @Test func inventoryRejectsProjectOrWorktreeFieldsWithoutLeakingThem() {
        let json = #"{"profiles":[{"name":"default","model":"gpt","gateway":"running","cwd":"/Users/example/Projects/secret","worktree":"/tmp/worktree"}],"connections":[]}"#
        let result = HermesProfileService.parse(json, format: .json)
        let encoded = String(describing: result)

        #expect(result.state == .malformed)
        #expect(result.profiles.isEmpty)
        #expect(!encoded.contains("Projects/secret"))
        #expect(!encoded.contains("worktree"))
        #expect(!encoded.contains("cwd"))
    }

    @Test func unsafeIdentityFieldsAreRejectedBeforeEnteringInventory() {
        let json = #"{"profiles":[{"name":"default","model":"https://user:token@example.com/key","gateway":"running"}],"connections":[]}"#

        let result = HermesProfileService.parse(json, format: .json)

        #expect(result.state == .malformed)
        #expect(result.profiles.isEmpty)
        #expect(!String(describing: result).contains("example.com"))
    }

    @Test func rejectsUnknownKeysInsteadOfSilentlyDroppingThem() {
        let json = #"{"profiles":[{"name":"default","model":"gpt","gateway":"running","unknown":"value"}],"connections":[]}"#

        let result = HermesProfileService.parse(json, format: .json)

        #expect(result.state == .malformed)
        #expect(result.profiles.isEmpty)
    }

    @Test func rejectsWrongTypesForPresentOptionalFields() {
        let modelNumber = #"{"profiles":[{"name":"default","model":7,"gateway":"running"}],"connections":[]}"#
        let activeString = #"{"profiles":[{"name":"default","model":"gpt","gateway":"running","is_active":"true"}],"connections":[]}"#
        let labelNumber = #"{"profiles":[],"connections":[{"profile":"default","status":"ready","label":7}]}"#
        let transportNumber = #"{"profiles":[],"connections":[{"profile":"default","status":"ready","transport":7}]}"#
        let modelPath = #"{"profiles":[{"name":"default","model":"models/gpt-5","gateway":"running"}],"connections":[]}"#

        #expect(HermesProfileService.parse(modelNumber, format: .json).state == .malformed)
        #expect(HermesProfileService.parse(activeString, format: .json).state == .malformed)
        #expect(HermesProfileService.parse(labelNumber, format: .json).state == .malformed)
        #expect(HermesProfileService.parse(transportNumber, format: .json).state == .malformed)
        #expect(HermesProfileService.parse(modelPath, format: .json).state == .malformed)
    }
}
