import Foundation
import Testing

@testable import Herm

@MainActor
struct PerformanceAuditRegressionTests {
    @Test func revisionSnapshotRetainsOrderingAndHandlesLongReverseChains() throws {
        let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == "metrics" })
        let source = RichFeatureRegistry.exampleSurface(descriptor)
        let original = try JSONDecoder().decode(RichSurface.self, from: Data(source.utf8))
        var records: [ArtifactRecord] = []
        var previous: RichArtifactReference?
        for row in 1...300 {
            var surface = original
            surface.revisionOf = previous
            let reference = RichArtifactReference(
                profileID: "p", sessionID: "session", rowID: row, messageUID: nil,
                surfaceID: "example", sourceDigest: "digest")
            records.append(
                ArtifactRecord(
                    value: "", sessionID: "session", sessionTitle: "Session",
                    timestamp: Date(timeIntervalSince1970: Double(row)), profileID: "p",
                    generated: .init(reference: reference, surface: surface, source: source)))
            previous = reference
        }
        let newest = try #require(records.last)
        let reverse = Array(records.reversed())
        let snapshot = RichArtifactIndex.Snapshot(reverse)
        #expect(snapshot.latest.map(\.id) == [newest.id])
        #expect(snapshot.versions(of: newest).map(\.id) == reverse.map(\.id))
        let truncated = RichArtifactIndex.Snapshot(Array(reverse.prefix(20)))
        #expect(truncated.latest.map(\.id) == [newest.id])
        #expect(truncated.versions(of: newest).count == 20)
    }

    @Test func artifactProjectionReusesUnchangedInputsAndInvalidatesFilters() {
        let record = ArtifactRecord(value: "/tmp/example.png", sessionID: "s", sessionTitle: "Session", timestamp: .now)
        let index = RichArtifactIndex.Snapshot([record])
        let cache = ArtifactBrowserProjectionCache()
        for _ in 0..<20 {
            let value = cache.project(
                index: index, query: "", kind: nil, savedOnly: false,
                bookmarks: [], resources: [], isSaved: { _ in false })
            #expect(value.images == 1)
            #expect(value.visible.count == 1)
        }
        #expect(cache.buildCount == 1)
        let filtered = cache.project(
            index: index, query: "missing", kind: nil, savedOnly: false,
            bookmarks: [], resources: [], isSaved: { _ in false })
        #expect(filtered.visible.isEmpty)
        #expect(filtered.total == 1)
        #expect(cache.buildCount == 2)
        let changed = cache.project(
            index: RichArtifactIndex.Snapshot([]), query: "missing", kind: nil,
            savedOnly: false, bookmarks: [], resources: [], isSaved: { _ in false })
        #expect(changed.total == 0)
        #expect(cache.buildCount == 3)
    }

    @Test func activityRevisionRequiresActualRecencyAndMessageCount() {
        #expect(LatestActivityRevision(["started_at": 100, "message_count": 2]) == nil)
        #expect(LatestActivityRevision(["updated_at": 100]) == nil)
        let first = LatestActivityRevision(["updated_at": 100, "message_count": 2, "profile": "one"])
        #expect(first != nil)
        #expect(first != LatestActivityRevision(["updated_at": 100, "message_count": 3, "profile": "one"]))
        #expect(first != LatestActivityRevision(["updated_at": 100, "message_count": 2, "profile": "two"]))
    }

    @Test func automaticArtifactInvalidationReadsOnlyTheChangedSession() async {
        let sessions = ["one", "two"].map {
            HermesSession(
                id: $0, title: $0, preview: "", startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 100), messageCount: 1, source: "hermes")
        }
        let cache = Dictionary(
            uniqueKeysWithValues: sessions.map {
                ($0.scopedID, ArtifactIndexLoader.CachedSession(session: $0, records: []))
            })
        var reads: [String] = []
        _ = await ArtifactIndexLoader.load(
            sessions: sessions, cache: cache,
            invalidatedSessions: [sessions[0].scopedID]
        ) { session, _ in
            reads.append(session.id)
            return ["data": []]
        }
        #expect(reads == ["one"])
    }

    @Test func diffOffsetsIncludeUnicodeAndEmptyAlignmentRows() {
        let offsets = DiffLineOffsets(lengths: ["🙂".utf16.count, 0, "abc".utf16.count])
        #expect(offsets.starts == [0, 3, 4])
        #expect(offsets.row(containing: 2) == 0)
        #expect(offsets.row(containing: 3) == 1)
        #expect(offsets.row(containing: 4) == 2)
        #expect(offsets.row(containing: 100) == 2)
        let large = DiffLineOffsets(lengths: Array(repeating: 9, count: 10_000))
        #expect(large.row(containing: 99_995) == 9_999)
    }

    @Test func archiveEnrichmentDoesNotBlockCoreRefreshAndCoalesces() async throws {
        let client = HeldActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.refresh()
        for _ in 0..<200 {
            if client.archiveStarted && client.agentRead { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.archiveStarted)
        #expect(client.agentRead)
        control.refreshLatestActivityProjection()
        #expect(client.archiveReads == 1)
        control.latestActivityRefreshTask?.cancel()
        for _ in 0..<200 {
            if control.latestActivityRefreshTask == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(control.latestActivityRefreshTask == nil)
        #expect(client.archiveReads == 1)
    }

    @Test func unchangedArchiveSessionsReuseStepsAndChangedMetadataRereads() async throws {
        let client = ActivityCacheClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        for expectedReads in [1, 1, 2] {
            if expectedReads == 2 { client.messageCount = 3 }
            try await control.refreshLatestActivities(
                rpc: HermesControlRPC(client: client), generation: 0, clientIdentity: nil)
            #expect(client.messageReads == expectedReads)
        }
        #expect(control.latestActivities.count == 1)
    }

    @Test func deletingBrowserWorkspaceReleasesOnlyItsOwnTabs() {
        let store = SessionBrowserStore()
        let key = SessionBrowserKey(profileID: "p", sessionID: "deleted")
        let otherKey = SessionBrowserKey(profileID: "p", sessionID: "retained")
        let deleted = store.workspace(for: key)
        _ = deleted.addTab()
        let retained = store.workspace(for: otherKey)
        store.presentation = key
        store.remove(key)
        #expect(deleted.extras.isEmpty)
        #expect(store.presentation == nil)
        #expect(store.workspace(for: otherKey) === retained)
        #expect(store.workspace(for: key) !== deleted)
    }
}

@MainActor
private final class HeldActivityClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var archiveStarted = false
    var archiveReads = 0
    var agentRead = false
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == HermesFeatureIDs.ID.delegationStatus.rawValue { agentRead = true }
        return ["sessions": [], "jobs": [], "agents": [], "processes": [], "projects": []]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/sessions?") {
            archiveStarted = true
            archiveReads += 1
            try await Task.sleep(for: .seconds(60))
            return ["data": [], "has_more": false]
        }
        return ["data": [], "has_more": false]
    }
}

@MainActor
private final class ActivityCacheClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var messageReads = 0
    var messageCount = 2
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/sessions?") {
            return [
                "data": [
                    [
                        "id": "s", "title": "Session", "updated_at": 100,
                        "message_count": messageCount,
                    ]
                ], "has_more": false,
            ]
        }
        messageReads += 1
        return ["data": [["id": "1", "role": "assistant", "timestamp": 100]]]
    }
}
