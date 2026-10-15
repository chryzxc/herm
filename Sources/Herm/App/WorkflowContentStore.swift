import Foundation

struct SavedQuickAction: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  var title: String
  var instructions: String
  var destination: QuickDestination?

  static let starters: [Self] = [
    Self(
      title: "Review patch",
      instructions:
        "Review the supplied patch. Identify concrete bugs and risks, explain their impact, and suggest focused corrections."
    ),
    Self(
      title: "Compare sources",
      instructions:
        "Compare the supplied sources. Explain agreements, disagreements and missing evidence, and identify the source of each conclusion."
    ),
    Self(
      title: "Explain screenshot",
      instructions:
        "Explain the supplied screenshot. Describe the visible information, identify relevant problems, and suggest practical next steps without guessing hidden state."
    ),
    Self(
      title: "Summarize material",
      instructions:
        "Summarize the supplied material. Highlight decisions, unresolved questions and next actions, preserving relevant source references."
    ),
  ]
}

struct WorkingSetCheckpoint: Codable, Equatable, Sendable {
  let workingSetID: UUID
  var note: String
  var destinationKey: String
  var draftID: UUID?
  var updatedAt = Date()
}

/// User-authored content is separate from reference preferences and recoverable messages.
@MainActor
final class WorkflowContentStore: ObservableObject {
  static let shared = WorkflowContentStore(
    directory: FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Herm/WorkflowContent", isDirectory: true))
  private struct Envelope: Codable, Sendable {
    var version = 1
    var actions: [SavedQuickAction]
    var checkpoints: [WorkingSetCheckpoint]
  }
  @Published private(set) var actions = SavedQuickAction.starters
  @Published private(set) var checkpoints: [WorkingSetCheckpoint] = []
  @Published private(set) var error: String?
  private let directory: URL?
  private let writes = DispatchQueue(label: "herm.workflow-content.writer")
  private var pending: DispatchWorkItem?
  private(set) var canWrite = true

  init(directory: URL? = nil) {
    self.directory = directory
    guard let directory else { return }
    let file = directory.appendingPathComponent("content-v1.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do {
      guard
        (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024
      else {
        throw ContentError.invalid
      }
      let saved = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
      guard saved.version == 1, Set(saved.actions.map(\.id)).count == saved.actions.count,
        Set(saved.checkpoints.map(\.workingSetID)).count == saved.checkpoints.count
      else {
        throw ContentError.invalid
      }
      for action in saved.actions { try Self.validate(action) }
      guard saved.checkpoints.allSatisfy({ $0.note.count <= 4_000 }) else {
        throw ContentError.invalid
      }
      actions = saved.actions
      checkpoints = saved.checkpoints
    } catch {
      self.error = "Workflow content could not be restored. The existing file is preserved."
      canWrite = false
    }
  }

  func save(_ action: SavedQuickAction) throws {
    guard canWrite else { throw ContentError.unavailable }
    try Self.validate(action)
    var action = action
    action.title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
    action.destination?.runtimeID = nil
    if let index = actions.firstIndex(where: { $0.id == action.id }) {
      actions[index] = action
    } else {
      actions.append(action)
    }
    scheduleSave()
  }

  func removeAction(_ id: UUID) {
    guard canWrite else { return }
    actions.removeAll { $0.id == id }
    scheduleSave()
  }

  func save(_ checkpoint: WorkingSetCheckpoint) throws {
    guard canWrite else { throw ContentError.unavailable }
    guard checkpoint.note.count <= 4_000, !checkpoint.destinationKey.isEmpty else {
      throw ContentError.noteTooLong
    }
    var checkpoint = checkpoint
    checkpoint.updatedAt = .now
    checkpoints.removeAll { $0.workingSetID == checkpoint.workingSetID }
    checkpoints.append(checkpoint)
    scheduleSave()
  }

  func clearCheckpoint(_ id: UUID) {
    guard canWrite else { return }
    checkpoints.removeAll { $0.workingSetID == id }
    scheduleSave()
  }

  func flush() {
    pending?.cancel()
    pending = nil
    guard canWrite, let directory else { return }
    let snapshot = Envelope(actions: actions, checkpoints: checkpoints)
    do {
      try writes.sync { try Self.write(snapshot, to: directory) }
      error = nil
    } catch {
      self.error = "Workflow content could not be saved. Keep Herm open and check file access."
    }
  }

  private func scheduleSave() {
    pending?.cancel()
    guard let directory else { return }
    let snapshot = Envelope(actions: actions, checkpoints: checkpoints)
    let work = Self.saveWork(snapshot, directory: directory) { [weak self] in
      self?.error = "Workflow content could not be saved. Keep Herm open and check file access."
    }
    pending = work
    writes.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  nonisolated private static func saveWork(
    _ snapshot: Envelope, directory: URL,
    failed: @escaping @MainActor @Sendable () -> Void
  ) -> DispatchWorkItem {
    DispatchWorkItem {
      do { try write(snapshot, to: directory) } catch { Task { @MainActor in failed() } }
    }
  }

  nonisolated private static func write(_ snapshot: Envelope, to directory: URL) throws {
    let data = try JSONEncoder().encode(snapshot)
    guard data.count <= 8 * 1024 * 1024 else { throw ContentError.invalid }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent("content-v1.json")
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  nonisolated private static func validate(_ action: SavedQuickAction) throws {
    guard !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      action.title.count <= 120,
      !action.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      action.instructions.count <= 12_000
    else { throw ContentError.invalidAction }
  }

  private enum ContentError: LocalizedError {
    case invalid, unavailable, invalidAction, noteTooLong
    var errorDescription: String? {
      switch self {
      case .invalid: "Workflow content exceeds its supported format or size."
      case .unavailable: "The existing workflow content file needs recovery before editing."
      case .invalidAction:
        "Enter a title up to 120 characters and instructions up to 12,000 characters."
      case .noteTooLong: "Checkpoint notes are limited to 4,000 characters."
      }
    }
  }
}
