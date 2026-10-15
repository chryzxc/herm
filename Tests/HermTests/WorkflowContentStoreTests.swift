import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkflowContentStoreTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func actionsAndCheckpointRestoreWithRestrictivePermissions() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowContentStore(directory: root)
    #expect(store.actions.count == 4)
    let destination = QuickDestination(
      profileID: "research", sessionID: "owner", runtimeID: "alias")
    let action = SavedQuickAction(
      title: "Research", instructions: "Compare evidence", destination: destination)
    try store.save(action)
    let checkpoint = WorkingSetCheckpoint(
      workingSetID: UUID(), note: "Waiting for review",
      destinationKey: destination.key, draftID: UUID())
    try store.save(checkpoint)
    store.flush()
    let restored = WorkflowContentStore(directory: root)
    #expect(restored.actions.first { $0.id == action.id }?.destination?.runtimeID == nil)
    #expect(restored.actions.first { $0.id == action.id }?.destination?.profileID == "research")
    #expect(restored.checkpoints.first?.draftID == checkpoint.draftID)
    #expect(restored.checkpoints.first?.note == checkpoint.note)
    let permissions = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("content-v1.json").path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(
      (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?
        .intValue == 0o700)
  }

  @Test func deletingStartersDoesNotReseedThemOnRestart() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowContentStore(directory: root)
    for action in store.actions { store.removeAction(action.id) }
    store.flush()
    #expect(WorkflowContentStore(directory: root).actions.isEmpty)
  }

  @Test func malformedContentIsPreservedAndEditingRefused() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("content-v1.json")
    let original = Data("unreadable user content".utf8)
    try original.write(to: file)
    let store = WorkflowContentStore(directory: root)
    #expect(!store.canWrite)
    #expect(store.error != nil)
    #expect(throws: (any Error).self) {
      try store.save(SavedQuickAction(title: "New", instructions: "Work"))
    }
    store.flush()
    #expect(try Data(contentsOf: file) == original)
  }

  @Test func checkpointReplacementAndRemovalKeepActions() throws {
    let store = WorkflowContentStore()
    let id = UUID()
    try store.save(WorkingSetCheckpoint(workingSetID: id, note: "First", destinationKey: "a"))
    try store.save(WorkingSetCheckpoint(workingSetID: id, note: "Second", destinationKey: "b"))
    #expect(store.checkpoints.count == 1)
    #expect(store.checkpoints.first?.note == "Second")
    store.clearCheckpoint(id)
    #expect(store.checkpoints.isEmpty)
    #expect(store.actions.count == 4)
    #expect(throws: (any Error).self) {
      try store.save(SavedQuickAction(title: "", instructions: "Work"))
    }
    #expect(throws: (any Error).self) {
      try store.save(
        WorkingSetCheckpoint(
          workingSetID: id, note: String(repeating: "x", count: 4_001), destinationKey: "a"))
    }
  }
}
