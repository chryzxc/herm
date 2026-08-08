import Foundation
import Testing
@testable import HermesAgentDock

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

}

private struct LegacyWorkspaceState: Encodable {
    let tasks: [WorkspaceTask]
    let agentRuns: [WorkspaceAgentRun]
    let projectPath: String?
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
