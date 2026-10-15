import Foundation
import Testing
@testable import Herm

@MainActor
struct WorkspaceStoreTests {
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

        store.attachProject(at: "/tmp/project", toSessions: [
            SessionSummary(id: "session-1", title: "First", state: "active", preview: nil),
            SessionSummary(id: "session-2", title: "Second", state: "idle", preview: nil)
        ])

        #expect(store.task(forSessionID: "session-1")?.projectPath == "/tmp/project")
        #expect(store.task(forSessionID: "session-2")?.projectPath == "/tmp/project")
    }

    @Test func viewedWorktreeIsScopedToItsSessionAndKeepsTheProject() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        store.attachProject(at: "/tmp/project", toSessions: [
            SessionSummary(id: "session-1", title: "First", state: "active", preview: nil),
            SessionSummary(id: "session-2", title: "Second", state: "idle", preview: nil)
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

        #expect(store.resolvedProjectPath(forSessionID: "project-session", hermesProjectPath: "/tmp/hermes-project") == "/tmp/hermes-project")
        #expect(store.resolvedProjectPath(forSessionID: "unbound-session", hermesProjectPath: nil) == nil)
        #expect(store.resolvedProjectPath(forSessionID: nil, hermesProjectPath: "/tmp/hermes-project") == nil)
    }

    @Test func migratesLegacySessionTasksAndCreatesOneBackup() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        let task = WorkspaceTask(title: "Legacy work", status: .done, projectPath: "/tmp/project", sessionID: "legacy-session")
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
            ControlReference(source: .hermesSession, sourceID: "session-1", sessionID: "session-1", projectID: "/tmp/project"),
            ControlReference(source: .hermesProject, sourceID: "project-1", projectID: "project-1"),
            ControlReference(source: .hermesCronJob, sourceID: "cron-1")
        ]
        try JSONEncoder.workspaceFixture.encode(CurrentWorkspaceState(
            schemaVersion: 2,
            tasks: [task],
            agentRuns: [],
            projectPath: "/tmp/project",
            controlReferences: references
        )).write(to: fixture.fileURL)

        let firstLoad = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(firstLoad.controlReferences == references)

        let persisted = try JSONDecoder.workspaceFixture.decode(CurrentWorkspaceState.self, from: Data(contentsOf: fixture.fileURL))
        #expect(persisted.controlReferences == references)

        let secondLoad = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(secondLoad.controlReferences == references)
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

private extension JSONEncoder {
    static var workspaceFixture: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var workspaceFixture: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct WorkspaceFixture {
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
