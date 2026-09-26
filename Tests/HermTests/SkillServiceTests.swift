import Foundation
import Testing
@testable import Herm

struct SkillServiceTests {
    @Test func parsesStrictReadOnlyInventoryAndLifecycleStatus() throws {
        let json = #"{"schema":"hermes.skills.inventory.v1","skills":[{"id":"builtin:planner","name":"planner","source":"builtin","installed":true,"enabled":true},{"id":"local:writer","name":"writer","source":"local","installed":true,"enabled":false}],"bundles":[{"id":"builtin","name":"Built-in","installed":true,"enabled":true}],"curator":{"status":"paused"},"memory":{"status":"built-in"}}"#

        let result = try HermesSkillService.parseVerifiedJSON(json)

        #expect(result.state == .ready)
        #expect(result.skills.map(\.id) == ["builtin:planner", "local:writer"])
        #expect(result.skills[1].isEnabled == false)
        #expect(result.bundles[0].name == "Built-in")
        #expect(result.curator.status == .paused)
        #expect(result.memory.status == .builtIn)
        #expect(result.mutations == .unavailable)
    }

    @Test func searchIsReadOnlyAndDoesNotInventResultsForUnsupportedTables() {
        let result = HermesSkillService.search("planner", output: "NAME SOURCE\nplanner builtin", format: .humanTable)

        #expect(result.state == .unsupported)
        #expect(result.results.isEmpty)
        #expect(result.diagnostic == "Human-readable skill output is unsupported.")
    }

    @Test func searchAcceptsOnlyCompleteDeclaredJSON() {
        let json = #"{"schema":"hermes.skills.search.v1","query":"planner","results":[{"id":"builtin:planner","name":"planner","source":"builtin","installed":true,"enabled":true}]}"#
        let result = HermesSkillService.search("planner", output: json, format: .json)

        #expect(result.state == .ready)
        #expect(result.results.map(\.name) == ["planner"])
    }

    @Test func rejectsUnknownFieldsAndDoesNotPartiallyRetainNames() {
        let json = #"{"schema":"hermes.skills.inventory.v1","skills":[{"id":"builtin:planner","name":"planner","source":"builtin","installed":true,"enabled":true,"content":"secret"}],"bundles":[],"curator":{"status":"ready"},"memory":{"status":"built-in"}}"#
        let result = HermesSkillService.parse(json, format: .json)

        #expect(result.state == .malformed)
        #expect(result.skills.isEmpty)
        #expect(result.bundles.isEmpty)
        #expect(!result.diagnostic.contains("planner"))
    }

    @Test func rejectsPromptsPathsURLsTokensAndUnboundedMetadata() {
        let json = #"{"schema":"hermes.skills.inventory.v1","skills":[{"id":"https://example.com/SKILL.md","name":"prompt: install","source":"/tmp/skills","installed":true,"enabled":true}],"bundles":[],"curator":{"status":"ready"},"memory":{"status":"built-in"}}"#
        let result = HermesSkillService.parse(json, format: .json)

        #expect(result.state == .malformed)
        #expect(result.skills.isEmpty)
    }

    @Test func absentMutationContractsAreExplicitlyUnavailable() {
        #expect(HermesSkillService.capability(.install) == .unavailable)
        #expect(HermesSkillService.capability(.configure) == .unavailable)
        #expect(HermesSkillService.capability(.bundleChange) == .unavailable)
        #expect(HermesSkillService.capability(.curatorMutation) == .unavailable)
        #expect(HermesSkillService.capability(.memoryWrite) == .unavailable)
    }

    @Test func rejectsDuplicateSkillAndBundleIdentity() {
        let json = #"{"schema":"hermes.skills.inventory.v1","skills":[{"id":"builtin:planner","name":"planner","source":"builtin","installed":true,"enabled":true},{"id":"builtin:planner","name":"planner-copy","source":"builtin","installed":true,"enabled":true}],"bundles":[{"id":"builtin","name":"Built-in","installed":true,"enabled":true},{"id":"builtin","name":"Built-in-copy","installed":true,"enabled":true}],"curator":{"status":"ready"},"memory":{"status":"built-in"}}"#

        let result = HermesSkillService.parse(json, format: .json)

        #expect(result.state == .malformed)
        #expect(result.skills.isEmpty)
        #expect(result.bundles.isEmpty)
    }
}
