import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkspaceStoreTests {
    @Test func profileOrderSurvivesStoreReconstruction() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let suite = "profile-order-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bots = ["a", "b"].map { id in
            BotSummary(
                id: id, name: id, title: nil, description: nil, model: nil,
                isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
                isHidden: false, hasAvatar: false, isDefault: id == "a")
        }
        let first = WorkspaceStore(fileURL: fixture.fileURL, profilePickerDefaults: defaults)
        first.profilePickerOrder.move("b", by: -1, in: bots)
        let second = WorkspaceStore(fileURL: fixture.fileURL, profilePickerDefaults: defaults)
        #expect(second.profilePickerOrder.ordered(bots) == [bots[1], bots[0]])
        #expect(first.tasks.isEmpty && second.tasks.isEmpty)
    }

    @Test func oneHermesSessionOwnsOneWorkspaceTask() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)

        let first = store.ensureTask(title: "Initial request", sessionID: "session-1")
        let enriched = store.ensureTask(title: "Resolved session title", sessionID: "session-1")

        #expect(first.id == enriched.id)
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.title == "Resolved session title")
    }

    @Test func sessionLookupFollowsInsertionsAndRemovals() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        let first = store.ensureTask(title: "First", sessionID: "session-1")
        _ = store.ensureTask(title: "Second", sessionID: "session-2")
        store.attachProject(at: "/tmp/one", toSessionID: "session-1")

        #expect(store.task(forSessionID: "session-1")?.id == first.id)
        #expect(store.projectPathsBySessionID == ["session-1": "/tmp/one"])
        store.deleteTask(first.id)
        #expect(store.task(forSessionID: "session-1") == nil)
        #expect(store.task(forSessionID: "session-2")?.title == "Second")
        #expect(store.projectPathsBySessionID.isEmpty)
    }

    @Test func statusUpdatePublishesOnceAndPreservesLookups() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        let task = store.ensureTask(title: "First", sessionID: "session-1")
        store.attachProject(at: "/tmp/project", toSessionID: "session-1")
        var publications = 0
        let subscription = store.$tasks.dropFirst().sink { _ in publications += 1 }

        store.updateStatus(.awaitingApproval, for: task.id)

        #expect(publications == 1)
        #expect(store.task(forSessionID: "session-1")?.status == .awaitingApproval)
        #expect(store.projectPathsBySessionID["session-1"] == "/tmp/project")
        store.updateTaskFromHermes(taskID: task.id, status: .inProgress, summary: "Updated")
        #expect(publications == 2)
        #expect(store.task(forSessionID: "session-1")?.summary == "Updated")
        #expect(store.projectPathsBySessionID["session-1"] == "/tmp/project")
        withExtendedLifetime(subscription) {}
    }

    @Test func statusUpdatesAreScopedToTheOwningSession() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        _ = store.ensureTask(title: "First", sessionID: "session-1")
        _ = store.ensureTask(title: "Second", sessionID: "session-2")

        store.updateStatus(.awaitingApproval, forSessionID: "session-1")

        #expect(store.task(forSessionID: "session-1")?.status == .awaitingApproval)
        #expect(store.task(forSessionID: "session-2")?.status == .inProgress)
    }

    @Test func projectFolderPropagatesToEverySessionInTheHermesProject() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)

        store.attachProject(
            at: "/tmp/project",
            toSessions: [
                SessionSummary(id: "session-1", title: "First", state: "active", preview: nil),
                SessionSummary(id: "session-2", title: "Second", state: "idle", preview: nil),
            ])

        #expect(store.task(forSessionID: "session-1")?.projectPath == "/tmp/project")
        #expect(store.task(forSessionID: "session-2")?.projectPath == "/tmp/project")
    }

    @Test func viewedWorktreeIsScopedToItsSessionAndKeepsTheProject() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        store.attachProject(
            at: "/tmp/project",
            toSessions: [
                SessionSummary(id: "session-1", title: "First", state: "active", preview: nil),
                SessionSummary(id: "session-2", title: "Second", state: "idle", preview: nil),
            ])

        store.setWorktreePath("/tmp/elsewhere/feature", forSessionID: "session-1", title: "First")
        store.setWorktreePath("/tmp/wt", forSessionID: "session-new", title: "New")

        #expect(store.worktreePath(forSessionID: "session-1") == "/tmp/elsewhere/feature")
        #expect(store.task(forSessionID: "session-1")?.projectPath == "/tmp/project")
        #expect(store.worktreePath(forSessionID: "session-2") == nil)
        #expect(store.worktreePath(forSessionID: "session-new") == "/tmp/wt")
    }

    @Test func selectedProjectFolderDoesNotLeakIntoUnrelatedSession() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)

        store.attachProject(at: "/tmp/selected-project")
        #expect(store.projectPath(forSessionID: nil) == nil)
        #expect(store.projectPath(forSessionID: "new-session") == nil)

        _ = store.ensureTask(title: "Session one", sessionID: "session-1")
        store.attachProject(at: "/tmp/session-project", toSessionID: "session-1")
        #expect(store.projectPath(forSessionID: "session-1") == "/tmp/session-project")
        #expect(store.projectPath(forSessionID: "another-session") == nil)
    }

    @Test func newSessionTaskDoesNotImplicitlyInheritGlobalProject() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)

        store.attachProject(at: "/tmp/selected-project")
        _ = store.ensureTask(title: "New chat", sessionID: "new-session")

        #expect(store.task(forSessionID: "new-session")?.projectPath == nil)
        #expect(store.projectPath(forSessionID: "new-session") == nil)
    }

    @Test func boundHermesProjectCanResolveRepositoryWithoutGlobalFallback() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)

        store.attachProject(at: "/tmp/global-project")

        #expect(
            store.resolvedProjectPath(forSessionID: "project-session", hermesProjectPath: "/tmp/hermes-project")
                == "/tmp/hermes-project")
        #expect(store.resolvedProjectPath(forSessionID: "unbound-session", hermesProjectPath: nil) == nil)
        #expect(store.resolvedProjectPath(forSessionID: nil, hermesProjectPath: "/tmp/hermes-project") == nil)
    }

    @Test func projectInventoryPublishesOneAttachmentAndSkipsUnchangedRefreshes() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        let existing = store.createTask(title: "Local title", sessionID: "existing")
        var taskUpdates = 0
        var referenceUpdates = 0
        var pathUpdates = 0
        let subscriptions = [
            store.$tasks.dropFirst().sink { _ in taskUpdates += 1 },
            store.$controlReferences.dropFirst().sink { _ in referenceUpdates += 1 },
            store.$projectPath.dropFirst().sink { _ in pathUpdates += 1 },
        ]
        let sessions = ["existing", "first", "existing", "second"].map { id in
            SessionSummary(id: id, title: id, state: "active", preview: nil)
        }
        store.attachProject(at: "/work/project", toSessions: sessions)
        #expect(taskUpdates == 1 && referenceUpdates == 1 && pathUpdates == 1)
        #expect(store.tasks.compactMap(\.sessionID) == ["second", "first", "existing"])
        #expect(store.controlReferences.map(\.sourceID) == ["existing", "first", "second"])
        #expect(store.task(forSessionID: "existing")?.id == existing.id)
        #expect(store.task(forSessionID: "existing")?.title == "Local title")
        #expect(store.projectPath(forSessionID: "first") == "/work/project")
        let attached = store.tasks

        store.attachProject(at: "/work/project", toSessions: sessions)
        #expect(taskUpdates == 1 && referenceUpdates == 1 && pathUpdates == 1)
        #expect(store.tasks == attached)
        withExtendedLifetime(subscriptions) {}
    }

    @Test func attachmentBeforeTaskCreationSurvivesSessionSynchronizationAndReload() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)

        store.attachProject(at: "/tmp/session-project", toSessionID: "session-1")
        store.ensureTask(title: "Restored title", sessionID: "session-1")
        var restored = WorkspaceStore(fileURL: fixture.fileURL)
        for _ in 0..<100 where restored.task(forSessionID: "session-1")?.title != "Restored title" {
            try await Task.sleep(for: .milliseconds(10))
            restored = WorkspaceStore(fileURL: fixture.fileURL)
        }

        #expect(restored.tasks.count == 1)
        #expect(restored.task(forSessionID: "session-1")?.title == "Restored title")
        #expect(restored.projectPath(forSessionID: "session-1") == "/tmp/session-project")
        #expect(restored.projectPath(forSessionID: "other-session") == nil)
    }

    @Test func createdSessionFolderResolvesBeforeProjectMembershipArrives() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        store.attachProject(at: "/tmp/unrelated")

        #expect(
            store.resolvedProjectPath(
                forSessionID: "new", hermesProjectPath: nil, createdSessionProjectPath: "/tmp/created")
                == "/tmp/created")
        #expect(
            store.resolvedProjectPath(
                forSessionID: "new", hermesProjectPath: "Project name", createdSessionProjectPath: "/tmp/created")
                == "/tmp/created")
        #expect(
            store.resolvedProjectPath(
                forSessionID: "new", hermesProjectPath: "/tmp/reported", createdSessionProjectPath: "/tmp/created")
                == "/tmp/reported")
        #expect(
            store.resolvedProjectPath(
                forSessionID: nil, hermesProjectPath: nil, createdSessionProjectPath: "/tmp/created") == nil)
        #expect(
            store.resolvedProjectPath(
                forSessionID: "new", hermesProjectPath: nil, createdSessionProjectPath: "relative") == nil)
        store.attachProject(at: "/tmp/attached", toSessionID: "new")
        #expect(
            store.resolvedProjectPath(
                forSessionID: "new", hermesProjectPath: "/tmp/reported", createdSessionProjectPath: "/tmp/created")
                == "/tmp/attached")
    }

    @Test func migratesLegacySessionTasksAndCreatesOneBackup() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        let task = WorkspaceTask(
            title: "Legacy work", status: .done, projectPath: "/tmp/project", sessionID: "legacy-session")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LegacyWorkspaceState(tasks: [task], agentRuns: [], projectPath: "/tmp/project"))
            .write(to: fixture.fileURL)

        let store = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(store.controlReferences.count == 1)
        #expect(store.controlReferences.first?.source == .hermesSession)
        #expect(store.controlReferences.first?.sourceID == "legacy-session")
        #expect(store.tasks.first?.status == .done)

        let backupURL = fixture.fileURL.deletingPathExtension().appendingPathExtension("v1.backup.json")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        _ = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test func currentSchemaReloadPreservesAllControlReferences() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        let task = WorkspaceTask(title: "Session work", projectPath: "/tmp/project", sessionID: "session-1")
        let references = [
            ControlReference(
                source: .hermesSession, sourceID: "session-1", sessionID: "session-1", projectID: "/tmp/project"),
            ControlReference(source: .hermesProject, sourceID: "project-1", projectID: "project-1"),
            ControlReference(source: .hermesCronJob, sourceID: "cron-1"),
        ]
        try JSONEncoder.workspaceFixture.encode(
            CurrentWorkspaceState(
                schemaVersion: 2,
                tasks: [task],
                agentRuns: [],
                projectPath: "/tmp/project",
                controlReferences: references
            )
        ).write(to: fixture.fileURL)

        let firstLoad = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(firstLoad.controlReferences == references)

        let persisted = try JSONDecoder.workspaceFixture.decode(
            CurrentWorkspaceState.self, from: Data(contentsOf: fixture.fileURL))
        #expect(persisted.controlReferences == references)

        let secondLoad = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(secondLoad.controlReferences == references)
    }

    @Test func corruptWorkspaceSurvivesSubsequentSave() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let corruptBytes = Data("{ invalid workspace JSON".utf8)
        try corruptBytes.write(to: fixture.fileURL)
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        store.attachProject(at: "/tmp/corrupt-workspace-project")

        try #require(WorkspaceStatePersistence.flushPendingSaves())
        #expect(store.projectPath == "/tmp/corrupt-workspace-project")
        #expect(try Data(contentsOf: fixture.fileURL) == corruptBytes)
    }

}

private struct LegacyWorkspaceState: Encodable {
    let tasks: [WorkspaceTask]
    let agentRuns: [WorkspaceAgentRun]
    let projectPath: String?
}

private struct CurrentWorkspaceState: Codable {
    let schemaVersion: Int
    let tasks: [WorkspaceTask]
    let agentRuns: [WorkspaceAgentRun]
    let projectPath: String?
    let controlReferences: [ControlReference]
}

extension JSONEncoder {
    fileprivate static var workspaceFixture: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var workspaceFixture: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct WorkspaceFixture {
    let directory: URL
    let fileURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
