import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct PerformanceAuditRegressionTests {
    @MainActor @Test func demandRemainsVisibleUntilLastHostHides() {
        let demand = DockPresentationDemand()
        let first = UUID()
        let second = UUID()
        demand.update(first, visible: true)
        demand.update(second, visible: true)
        demand.update(first, visible: false)
        #expect(demand.hasVisibleHost)
        demand.update(second, visible: false)
        #expect(!demand.hasVisibleHost)
    }
    @Test func archiveReadsAreLimitedToTwoAndKeepAllSessions() async throws {
        let client = ArchiveConcurrencyClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        try await control.refreshLatestActivities(
            rpc: HermesControlRPC(client: client), generation: control.refreshGeneration, clientIdentity: nil)
        #expect(client.maximumConcurrent == 2)
        #expect(client.completed == 8)
        #expect(control.latestActivities.count == 8)
    }
    @Test func workspaceObservationSkipsBackgroundActivityButKeepsNavigation() async throws {
        let model = DockModel(initialSessionID: "workspace-one")
        let control = ControlCenterModel()
        var modelUpdates = 0
        var controlUpdates = 0
        let modelSubscription = model.workspacePresentationChanges.sink { modelUpdates += 1 }
        let controlSubscription = control.workspacePresentationChanges.sink { controlUpdates += 1 }
        model.activityPresentationRevision += 1
        control.pendingActionIDs.insert("unrelated")
        try await Task.sleep(for: .milliseconds(20))
        #expect(modelUpdates == 0)
        #expect(controlUpdates == 0)
        model.sessionID = "workspace-two"
        control.projects = []
        try await Task.sleep(for: .milliseconds(20))
        #expect(modelUpdates > 0)
        #expect(controlUpdates > 0)
        withExtendedLifetime((modelSubscription, controlSubscription)) {}
    }

    @Test func repeatedLiveConnectionDoesNotRedrawWorkspace() async throws {
        let model = DockModel(initialSessionID: "connection-one")
        model.gateway.onConnectionChange?(true)
        try await Task.sleep(for: .milliseconds(20))
        var updates = 0
        let subscription = model.workspacePresentationChanges.sink { updates += 1 }
        model.gateway.onConnectionChange?(true)
        model.gateway.onConnectionChange?(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(updates == 0)
        #expect(model.isHermesConnected)
        withExtendedLifetime(subscription) {}
    }

    @Test func inspectorObservationSkipsActivityButKeepsSessionInputs() async throws {
        let model = DockModel(initialSessionID: "inspector-one")
        var updates = 0
        let subscription = model.inspectorPresentationChanges.sink { updates += 1 }
        model.activityPresentationRevision += 1
        model.messages.append(ChatMessage(role: .hermes, text: "tick"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(updates == 0)
        model.currentSessionTitle = "Renamed"
        try await Task.sleep(for: .milliseconds(20))
        #expect(updates > 0)
        withExtendedLifetime(subscription) {}
    }

    @Test func stalledRoutineDoesNotBlockSessionsOrAgents() async throws {
        let client = HeldActivityClient()
        client.holdRoutine = true
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.refresh()
        defer {
            control.routineInventoryTask?.cancel()
            control.refreshTask?.cancel()
            control.latestActivityRefreshTask?.cancel()
        }
        for _ in 0..<200 {
            if client.routineStarted && client.agentRead && !control.activeSessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.routineStarted)
        #expect(client.agentRead)
        #expect(control.activeSessions.map(\.id) == ["active"])
        #expect(control.isRefreshing)
    }

    @Test func rebindingTheSameModelDoesNotRestartKanban() async throws {
        let client = HeldActivityClient()
        let model = DockModel(initialSessionID: "bind-test", rpcClient: client)
        let control = ControlCenterModel()
        control.bind(to: model)
        for _ in 0..<100 where control.hasKanbanReadInFlight || !control.pendingActionIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = client.requestCount
        let generation = control.clientBindingGeneration
        control.bind(to: model)
        control.bind(to: model)
        try await Task.sleep(for: .milliseconds(30))
        #expect(client.requestCount == requests)
        #expect(control.clientBindingGeneration == generation)
        let replacement = DockModel(initialSessionID: "other", rpcClient: client)
        control.bind(to: replacement)
        #expect(control.clientBindingGeneration == generation + 1)
        #expect(control.dockModel === replacement)
    }

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

    @Test func boundedEventValueTruncatesOnlyStringsLongerThanTheLimit() {
        let long = String(repeating: "a", count: 1_000_000)
        #expect(DockModel.boundedEventValue(long, depth: 0) as? String == String(repeating: "a", count: 240) + "…")
        // 200 emoji exceed 240 UTF-16 units but stay under 240 characters.
        let emoji = String(repeating: "😀", count: 200)
        #expect(DockModel.boundedEventValue(emoji, depth: 0) as? String == emoji)
        #expect(DockModel.boundedEventValue("short", depth: 0) as? String == "short")
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
private final class ArchiveConcurrencyClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var concurrent = 0
    var maximumConcurrent = 0
    var completed = 0
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/sessions?") {
            return [
                "data": (0..<8).map {
                    [
                        "id": "s\($0)", "title": "Session \($0)", "updated_at": 100,
                        "message_count": 1,
                    ]
                }, "has_more": false,
            ]
        }
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        completed += 1
        return ["data": [["id": "1", "role": "assistant", "timestamp": 100, "tool_name": "terminal"]]]
    }
}

@MainActor
private final class HeldActivityClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var archiveStarted = false
    var archiveReads = 0
    var agentRead = false
    var requestCount = 0
    var holdRoutine = false
    var routineStarted = false
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requestCount += 1
        if holdRoutine, method == HermesFeatureIDs.ID.cronManage.rawValue, params["action"] as? String == "list" {
            routineStarted = true
            try await Task.sleep(for: .seconds(60))
        }
        if method == HermesFeatureIDs.ID.delegationStatus.rawValue { agentRead = true }
        if holdRoutine, method == HermesFeatureIDs.ID.sessionActiveList.rawValue {
            return ["sessions": [["id": "active", "title": "Active"]]]
        }
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

struct HermPerformanceRecorderTests {
    @Test func droppedFramesIgnoresJitterAndCountsWholeMissedFrames() {
        let frame = 1.0 / 120
        #expect(HermPerformanceRecorder.droppedFrames(delta: frame, expected: frame) == 0)
        #expect(HermPerformanceRecorder.droppedFrames(delta: frame * 1.4, expected: frame) == 0)
        #expect(HermPerformanceRecorder.droppedFrames(delta: frame * 2, expected: frame) == 1)
        #expect(HermPerformanceRecorder.droppedFrames(delta: 0.1, expected: frame) == 11)
        #expect(HermPerformanceRecorder.droppedFrames(delta: 0, expected: frame) == 0)
    }
}

struct WorkspaceMessageKeyTests {
    @Test func streamingTextReachesTheRootOnlyInVoice() {
        let user = ChatMessage(role: .user, text: "Hi")
        var reply = ChatMessage(role: .hermes, text: "Hel")
        let id = reply.id
        let before = DockModel.workspaceMessageKey([user, reply], voiceActive: false)
        reply = ChatMessage(role: .hermes, text: "Hello")
        reply.id = id
        #expect(DockModel.workspaceMessageKey([user, reply], voiceActive: false) == before)
        #expect(
            DockModel.workspaceMessageKey([user, reply], voiceActive: true)
                != DockModel.workspaceMessageKey([user, ChatMessage(role: .hermes, text: "Hel")], voiceActive: true))
        #expect(DockModel.workspaceMessageKey([user], voiceActive: false) != before)
    }
}
