import Foundation
import Testing

@testable import Herm

@Suite struct HermesCompatibilityTests {
    private func contract(type: String = "string", description: String = "Original", titleType: String = "string")
        throws -> Data
    {
        try JSONSerialization.data(withJSONObject: [
            "methods": [["name": "session.resume", "params": [["schema": ["$ref": "#/components/schemas/Reply"]]]]],
            "x-canonical-methods": [], "x-server-requests": [], "x-notifications": [],
            "components": [
                "schemas": [
                    "Reply": [
                        "type": "object",
                        "properties": [
                            "value": ["$ref": "#/components/schemas/Value"], "title": ["type": titleType],
                        ],
                    ],
                    "Value": ["type": type, "description": description],
                ]
            ],
        ])
    }

    private func baseline(_ signatures: [String: String]) -> HermesCompatibilityBaseline {
        HermesCompatibilityBaseline(
            formatVersion: 1, revision: String(repeating: "a", count: 40), reviewedAt: "2026-11-05",
            trackedMethods: ["session.resume"], signatures: signatures, backlog: [])
    }

    @Test func transitiveChangesAndNamedTitlePropertiesAreDetected() throws {
        let original = try HermesCompatibilityContract.signatures(data: contract())
        let prose = try HermesCompatibilityContract.signatures(data: contract(description: "Reworded"))
        #expect(original == prose)
        #expect(original != (try HermesCompatibilityContract.signatures(data: contract(type: "integer"))))
        #expect(original != (try HermesCompatibilityContract.signatures(data: contract(titleType: "integer"))))
    }

    @Test func removedUsedMethodsAndEventsRankBeforeFeatureCandidates() {
        let reviewed = baseline([
            "rpc:session.resume": "old", "rpc:unused": "old", "event:message.delta": "old",
        ])
        let changes = HermesCompatibilityContract.changes(
            baseline: reviewed,
            current: ["rpc:unused": "new", "event:message.delta": "new", "rpc:subagent.roster": "new"])
        #expect(
            changes == [
                .init(id: "rpc:session.resume", kind: .removed),
                .init(id: "event:message.delta", kind: .changed),
                .init(id: "rpc:subagent.roster", kind: .added),
            ])
    }

    @Test func malformedAndDanglingContractsFailClosed() throws {
        #expect(throws: (any Error).self) { try HermesCompatibilityContract.signatures(data: Data("{}".utf8)) }
        let root: [String: Any] = [
            "methods": [["name": "session.resume", "params": [["$ref": "#/components/schemas/Missing"]]]],
            "components": ["schemas": [:]], "x-canonical-methods": [], "x-server-requests": [], "x-notifications": [],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: (any Error).self) { try HermesCompatibilityContract.signatures(data: bytes) }
        #expect(!HermesCompatibilityContract.validRevision("main"))
        #expect(!HermesCompatibilityContract.validRevision(String(repeating: "z", count: 40)))
    }

    @Test func recursiveSchemaTerminatesAndKeepsDefaults() throws {
        func recursive(_ enabled: Bool) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "methods": [["name": "session.resume", "params": [["$ref": "#/components/schemas/Node"]]]],
                "x-canonical-methods": [], "x-server-requests": [], "x-notifications": [],
                "components": [
                    "schemas": [
                        "Node": [
                            "type": "object",
                            "properties": [
                                "next": ["$ref": "#/components/schemas/Node"],
                                "enabled": ["type": "boolean", "default": enabled],
                            ],
                        ]
                    ]
                ],
            ])
        }
        let first = try HermesCompatibilityContract.signatures(data: recursive(true))
        let second = try HermesCompatibilityContract.signatures(data: recursive(false))
        #expect(first.count == 1)
        #expect(first != second)
    }

    @MainActor @Test func bundledBaselineLoadsWithKnownWorkAndCurrentTransportCoverage() throws {
        let reviewed = try HermesCompatibilityService.bundledBaseline()
        #expect(reviewed.backlog.count == 7)
        #expect(reviewed.signatures.count > 300)
        let declared = Set(reviewed.trackedMethods)
        for method in HermesFeatureIDs.transportIDs where reviewed.signatures["rpc:\(method)"] != nil {
            #expect(declared.contains(method), "Add new Herm contracts to the tracker’s reviewed method set")
        }
    }

    @MainActor @Test func failedRefreshKeepsLastSuccessfulSnapshotAndCanRetry() async throws {
        let bytes = try contract()
        let signatures = try HermesCompatibilityContract.signatures(data: bytes)
        let feed = CompatibilityFeed(contract: bytes)
        let service = HermesCompatibilityService(baseline: baseline(signatures), fetch: { try await feed.read() })
        await service.check()
        let checked = service.checkedAt
        #expect(checked != nil)
        #expect(service.error == nil)
        await service.check()
        #expect(await feed.calls == 1)
        await feed.setFailure(true)
        await service.check(force: true)
        #expect(service.error != nil)
        #expect(service.checkedAt == checked)
        #expect(service.upstreamRevision == String(repeating: "b", count: 40))
        #expect(!service.isChecking)
        await feed.setFailure(false)
        await service.check(force: true)
        #expect(service.error == nil)
        #expect(service.changes.isEmpty)
    }
}

private actor CompatibilityFeed {
    let contract: Data
    var calls = 0
    var fails = false
    init(contract: Data) { self.contract = contract }
    func setFailure(_ value: Bool) { fails = value }
    func read() throws -> HermesCompatibilityRemote {
        calls += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return HermesCompatibilityRemote(revision: String(repeating: "b", count: 40), contract: contract)
    }
}
