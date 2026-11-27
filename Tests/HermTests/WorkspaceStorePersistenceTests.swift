import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkspaceStorePersistenceTests {
    @Test func failedWorkspaceReadDisablesLaterWrites() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: false)
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        try FileManager.default.removeItem(at: fixture.fileURL)
        store.attachProject(at: "/tmp/unreadable-workspace-project")
        try #require(WorkspaceStatePersistence.flushPendingSaves())
        #expect(store.projectPath == "/tmp/unreadable-workspace-project")
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test func danglingWorkspaceSymlinkIsPreserved() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("missing.json")
        try FileManager.default.createSymbolicLink(at: fixture.fileURL, withDestinationURL: target)
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        store.attachProject(at: "/tmp/dangling-workspace-project")
        try #require(WorkspaceStatePersistence.flushPendingSaves())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.fileURL.path) == target.path)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func immediateQuitFlushPersistsLatestWorkspaceSave() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let store = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(store.projectPath == nil)
        let gateEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let flushReturned = DispatchSemaphore(value: 0)
        let coordinatorDone = DispatchSemaphore(value: 0)
        let returnedBeforeRelease = DispatchSemaphore(value: 0)
        WorkspaceStatePersistence.saveQueue.async {
            gateEntered.signal()
            _ = releaseWriter.wait(timeout: .now() + .seconds(5))
        }
        guard gateEntered.wait(timeout: .now() + .seconds(5)) == .success else {
            releaseWriter.signal()
            Issue.record("Workspace save queue did not reach the gate")
            return
        }
        store.attachProject(at: "/tmp/first-workspace-project")
        store.attachProject(at: "/tmp/latest-workspace-project")
        DispatchQueue.global().async {
            if flushReturned.wait(timeout: .now() + .milliseconds(200)) == .success {
                returnedBeforeRelease.signal()
            }
            releaseWriter.signal()
            coordinatorDone.signal()
        }
        let flushed = WorkspaceStatePersistence.flushPendingSaves()
        flushReturned.signal()
        #expect(coordinatorDone.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(returnedBeforeRelease.wait(timeout: .now()) == .timedOut)
        try #require(flushed)
        let restored = WorkspaceStore(fileURL: fixture.fileURL)
        #expect(restored.projectPath == "/tmp/latest-workspace-project")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func workspaceFlushTimesOutWithStalledQueue() {
        let queue = DispatchQueue(label: "workspace-flush-stalled-test")
        let release = DispatchSemaphore(value: 0)
        queue.async { _ = release.wait(timeout: .now() + .seconds(5)) }
        defer { release.signal() }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(!WorkspaceStatePersistence.drain(queue, timeout: .milliseconds(50)))
        #expect(start.duration(to: clock.now) < .seconds(3))
    }
}
