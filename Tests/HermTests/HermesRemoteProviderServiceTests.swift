import Foundation
import Testing

@testable import Herm

@MainActor
struct HermesRemoteProviderServiceTests {
    @Test func unknownAccountMarksPreviousReadingUnavailable() throws {
        let read = try HermesRemoteProviderService.partial(
            [
                "providers": [
                    [
                        "slug": "openai-codex",
                        "usage": ["accounts": [["id": "one", "state": "unknown", "windows": []]]],
                    ]
                ]
            ], profile: nil)
        let id = HermesRemoteProviderService.snapshotID(
            "codex-hermes", profile: nil, slug: "openai-codex", account: "one")
        #expect(read.unavailableIDs == [id])
        #expect(!read.malformed)
        #expect(read.snapshots.count == 1)
    }

    @Test func missingUsageIsDistinguishedFromMalformedData() throws {
        let read = try HermesRemoteProviderService.partial(
            ["providers": [["slug": "openai-codex"]]], profile: nil)
        #expect(!read.malformed)
        #expect(read.missingUsagePrefixes.count == 1)
        #expect(read.snapshots.isEmpty)
    }

    @Test func partialReadKeepsMalformedAccountAndPublishesValidSibling() throws {
        let result: [String: Any] = [
            "providers": [
                [
                    "slug": "openai-codex",
                    "usage": [
                        "accounts": [
                            ["id": "good", "state": "ready", "windows": [["label": "Week", "used_percent": 10]]],
                            ["id": "bad", "state": "ready"],
                        ]
                    ],
                ]
            ]
        ]
        let read = try HermesRemoteProviderService.partial(result, profile: nil)
        let badID = HermesRemoteProviderService.snapshotID(
            "codex-hermes", profile: nil, slug: "openai-codex", account: "bad")
        #expect(read.malformed)
        #expect(read.retainIDs == [badID])
        #expect(read.snapshots.count == 1)
        #expect(read.snapshots[0].windows.first?.remainingPercent == 90)
        let empty = try HermesRemoteProviderService.partial(
            ["providers": [["slug": "openai-codex", "usage": ["accounts": []]]]], profile: nil)
        #expect(!empty.malformed && empty.snapshots.isEmpty)
    }

    @Test func defaultProfileOverridesNondefaultGatewayAmbientProfile() async throws {
        let client = AmbientProfileClient()
        _ = try await HermesRemoteProviderService.readQuota(client: client, profile: nil)
        #expect(client.effectiveProfile == "default")
    }

    @Test func malformedUsageDoesNotReplaceSnapshots() {
        let invalid: [[String: Any]] = [
            [:],
            ["usage": "bad"],
            ["usage": ["accounts": "bad"]],
            ["usage": ["accounts": [["id": "one", "windows": []]]]],
            ["usage": ["accounts": [["id": "one", "state": "bogus", "windows": []]]]],
            ["usage": ["accounts": [["id": "one", "state": "ready"]]]],
            ["usage": ["accounts": [["id": "one", "windows": "bad"]]]],
            ["usage": ["windows": [["label": "Week", "used_percent": true]]]],
        ]
        for item in invalid {
            var row = item
            row["slug"] = "openai-codex"
            #expect(throws: (any Error).self) {
                try HermesRemoteProviderService.validateCatalog(["providers": [row]])
            }
        }
        #expect(throws: Never.self) {
            try HermesRemoteProviderService.validateCatalog([
                "providers": [["slug": "openai-codex", "usage": ["accounts": [[String: Any]]()]]]
            ])
        }
    }

    @Test func codexRemoteSnapshotResolvesBackendDescriptor() {
        let payload: [String: Any] = [
            "providers": [
                [
                    "slug": "openai-codex", "usage": ["windows": [["label": "Week", "used_percent": 25]]],
                ]
            ]
        ]
        let snapshots = HermesRemoteProviderService.snapshots(from: payload, profile: nil, now: .now)
        #expect(snapshots.count == 1)
        #expect(QuotaWorkspacePresentation.descriptor(forProvider: snapshots[0].provider)?.id == "codex-hermes")
    }

    @Test func missingProfileMeansExplicitDefault() {
        #expect(HermesRemoteProviderService.profileName(nil) == "default")
        #expect(HermesRemoteProviderService.profileName("work") == "work")
    }

    @Test func malformedCatalogIsNotAnEmptySuccess() {
        #expect(throws: (any Error).self) {
            try HermesRemoteProviderService.validateCatalog(["providers": "invalid"])
        }
        #expect(throws: Never.self) {
            try HermesRemoteProviderService.validateCatalog(["providers": [[String: Any]]()])
        }
    }

    @Test func separateAccountsAndMalformedSiblings() {
        let window: [String: Any] = ["label": "Weekly", "used_percent": 30.0]
        let valid: [String: Any] = ["id": "one", "label": "Work", "state": "ready", "windows": [window]]
        let invalid: [String: Any] = ["label": "Weekly", "used_percent": true]
        let broken: [String: Any] = ["id": "two", "label": "Home", "state": "ready", "windows": [invalid]]
        let usage: [String: Any] = ["accounts": [valid, broken]]
        let row: [String: Any] = ["slug": "openai-codex", "name": "Codex", "usage": usage]
        let snapshots = HermesRemoteProviderService.snapshots(from: ["providers": [row]], profile: "work", now: .now)
        #expect(snapshots.count == 2)
        #expect(snapshots[0].windows.first?.remainingPercent == 70)
        #expect(snapshots[1].windows.isEmpty)
        #expect(snapshots.allSatisfy { $0.hermesCredential == nil })
        let reversed: [String: Any] = ["accounts": [broken, valid]]
        let reordered: [String: Any] = ["slug": "openai-codex", "usage": reversed]
        let payload: [String: Any] = ["providers": [reordered]]
        let again = HermesRemoteProviderService.snapshots(from: payload, profile: "work", now: .now)
        #expect(again[0].provider == snapshots[1].provider)
        #expect(again[1].provider == snapshots[0].provider)
        let other = HermesRemoteProviderService.snapshots(from: payload, profile: "other", now: .now)
        #expect(other[0].provider != again[0].provider)
    }

    @Test func singletonAndUnsafeValues() {
        let valid: [String: Any] = ["label": "Limit", "used_percent": 120.0]
        let invalid: [String: Any] = ["label": "Invalid", "used_percent": "10"]
        let usage: [String: Any] = ["windows": [valid, invalid]]
        let row: [String: Any] = ["slug": "openrouter", "name": "OpenRouter", "usage": usage]
        let snapshots = HermesRemoteProviderService.snapshots(from: ["providers": [row]], profile: nil, now: .now)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].windows.count == 1)
        #expect(snapshots[0].windows[0].remainingPercent == 0)
    }
}

@MainActor
private final class AmbientProfileClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var effectiveProfile: String?
    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        effectiveProfile = params["profile"] as? String ?? "ambient-work"
        return ["providers": [[String: Any]]()]
    }
}
