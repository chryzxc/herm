import AppKit
import Combine
import CryptoKit
import Foundation

struct QuickDestination: Codable, Equatable, Sendable {
  var profileID: String?
  var sessionID: String?
  var runtimeID: String?
  var title = "New session"
  var projectPath: String?

  var key: String { "\(profileID ?? "")/\(sessionID ?? "new")/\(projectPath ?? "")" }
  var sessionKey: String { "\(profileID ?? "")/\(sessionID ?? "new")" }
  var session: HermesSession? {
    sessionID.map {
      HermesSession(
        id: $0, profileID: profileID, title: title, preview: "",
        startedAt: nil, messageCount: 0, source: "herm")
    }
  }
}

struct QuickDraftFile: Codable, Identifiable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case image, pdf, file }
  var id = UUID()
  let name: String
  let bookmark: Data
  let fallbackURL: URL
  let kind: Kind
  let digest: String
  let owned: Bool
  var byteCount: Int? = nil
  var modifiedAt: Date? = nil
  var uploadedPaths: [String] = []
  var reference: String?
  var uploaded = false

  func url() throws -> URL {
    var stale = false
    let resolved = try URL(
      resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale else { throw QuickDraftError.message("\(name) needs to be selected again.") }
    return resolved
  }

  static func capture(_ url: URL, owned: Bool = false) async throws -> Self {
    try await Task.detached(priority: .userInitiated) {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
      ])
      guard values.isRegularFile == true else {
        throw QuickDraftError.message("Folders are not supported.")
      }
      let ext = url.pathExtension.lowercased()
      let kind: Kind =
        ext == "pdf"
        ? .pdf
        : ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
          ? .image : .file
      let limit = kind == .pdf ? 25 * 1024 * 1024 : 50 * 1024 * 1024
      guard (values.fileSize ?? Int.max) <= limit else {
        throw QuickDraftError.message(
          kind == .pdf
            ? "PDF attachments are limited to 25 MB." : "Quick attachments are limited to 50 MB.")
      }
      let data = try Data(contentsOf: url)
      guard data.count <= limit else {
        throw QuickDraftError.message("The attachment exceeds its size limit.")
      }
      return Self(
        name: url.lastPathComponent,
        bookmark: try url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
        fallbackURL: url, kind: kind,
        digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), owned: owned,
        byteCount: data.count, modifiedAt: values.contentModificationDate)
    }.value
  }

  func encoded() async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let source = try url()
      let access = source.startAccessingSecurityScopedResource()
      defer { if access { source.stopAccessingSecurityScopedResource() } }
      let maximum = kind == .pdf ? 25 * 1024 * 1024 : 50 * 1024 * 1024
      let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximum else {
        throw QuickDraftError.message(
          "\(name) is missing or exceeds its size limit. Select it again.")
      }
      let data = try Data(contentsOf: source)
      guard data.count <= maximum,
        SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest
      else {
        throw QuickDraftError.message(
          "\(name) changed after capture. Remove it and select it again.")
      }
      return data.base64EncodedString()
    }.value
  }
}

extension QuickDraftFile {
  func referenceDiagnostic() async -> String? {
    await Task.detached(priority: .utility) {
      do {
        let source = try url()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ])
        guard values.isRegularFile == true else { return "File not found. Select it again." }
        if let byteCount, values.fileSize != byteCount { return "File changed. Select it again." }
        if let modifiedAt, values.contentModificationDate != modifiedAt {
          return "File changed. Select it again."
        }
        return nil
      } catch { return "Missing or inaccessible. Select this file again." }
    }.value
  }
}

enum QuickDraftError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

struct QuickDraftRecord: Codable, Identifiable, Equatable, Sendable {
  enum Delivery: String, Codable, Sendable { case editing, submitting, needsReview }
  var id = UUID()
  var revision = UUID()
  var destination: QuickDestination
  var text = ""
  var files: [QuickDraftFile] = []
  var sources: [String] = []
  var contexts: [ChatContext]? = nil
  var requestsVisualReply: Bool? = nil
  var savedName: String? = nil
  var uploadMessageCount: Int? = nil
  var uploadDirectory: String? = nil
  var delivery = Delivery.editing
  var updatedAt = Date()
  var isEmpty: Bool { text.isEmpty && files.isEmpty && sources.isEmpty && (contexts ?? []).isEmpty && delivery == .editing }
}

/// User content has its own file; Hermes state and transcripts never enter this store.
@MainActor
final class QuickDraftStore: ObservableObject {
  static let shared = QuickDraftStore(
    directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Herm/QuickDrafts", isDirectory: true))
  private struct Envelope: Codable {
    var version = 1
    var records: [QuickDraftRecord]
  }
  private let directory: URL?
  private let writes = DispatchQueue(label: "herm.quick-drafts.writer")
  private var scheduled: DispatchWorkItem?
  private var canWrite = true
  @Published private(set) var records: [QuickDraftRecord] = []
  @Published private(set) var error: String?

  init(directory: URL? = nil) {
    self.directory = directory
    guard let directory else { return }
    let file = directory.appendingPathComponent("drafts-v1.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do {
      guard
        (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024
      else {
        throw QuickDraftError.message("Draft recovery file exceeds its supported size.")
      }
      let data = try Data(contentsOf: file)
      guard data.count <= 8 * 1024 * 1024 else {
        throw QuickDraftError.message("Draft recovery file exceeds its supported size.")
      }
      let saved = try JSONDecoder().decode(Envelope.self, from: data)
      guard saved.version == 1, Set(saved.records.map(\.id)).count == saved.records.count else {
        throw QuickDraftError.message("Draft recovery file has an unsupported format.")
      }
      records = saved.records.map { record in
        var record = record
        if record.delivery == .submitting || record.files.contains(where: \.uploaded) {
          record.delivery = .needsReview
        }
        return record
      }
    } catch {
      self.error = "Draft recovery is unavailable. The existing recovery file has been preserved."
      canWrite = false
    }
  }

  func save(_ record: QuickDraftRecord) {
    guard canWrite else { return }
    var record = record
    record.updatedAt = .now
    if let index = records.firstIndex(where: { $0.id == record.id }) {
      if record.isEmpty { records.remove(at: index) } else { records[index] = record }
    } else if !record.isEmpty {
      records.append(record)
    }
    scheduleSave()
  }

  func remove(_ record: QuickDraftRecord) {
    records.removeAll { $0.id == record.id }
    scheduleSave()
    for file in record.files where file.owned { removeOwned(file.fallbackURL) }
  }

  func removeOwned(_ url: URL) {
    guard !records.contains(where: { $0.files.contains(where: { $0.fallbackURL == url }) || ($0.contexts ?? []).contains(where: { $0.attachmentURL == url }) }), let directory,
      ["images", "attachments"].contains(where: { url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.appendingPathComponent($0).resolvingSymlinksInPath() })
    else { return }
    writes.async { try? FileManager.default.removeItem(at: url) }
  }

  func storePastedText(_ data: Data) throws -> URL {
    guard data.count <= 8 * 1024 * 1024, let directory else { throw QuickDraftError.message("Draft attachment storage is unavailable.") }
    let folder = directory.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = folder.appendingPathComponent("paste-" + UUID().uuidString + ".txt")
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  func pasteImage(_ data: Data) async throws -> QuickDraftFile {
    guard data.count <= 50 * 1024 * 1024 else {
      throw QuickDraftError.message("Pasted images are limited to 50 MB.")
    }
    guard let directory else {
      throw QuickDraftError.message("Draft image storage is unavailable.")
    }
    let folder = directory.appendingPathComponent("images", isDirectory: true)
    let url = folder.appendingPathComponent(UUID().uuidString + ".png")
    try await Task.detached(priority: .userInitiated) {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      try data.write(to: url, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }.value
    return try await QuickDraftFile.capture(url, owned: true)
  }

  func flush() {
    scheduled?.cancel()
    scheduled = nil
    guard canWrite, let directory else { return }
    let snapshot = records
    do {
      try writes.sync { try Self.write(snapshot, to: directory) }
      self.error = nil
    } catch {
      self.error = "Quick drafts could not be saved. Keep Herm open and check file access."
    }
  }

  private func scheduleSave() {
    scheduled?.cancel()
    guard canWrite, let directory else { return }
    let work = Self.saveWork(records, to: directory) { [weak self] in
      self?.error = "Quick drafts could not be saved. Keep Herm open and check file access."
    }
    scheduled = work
    writes.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  /// Built outside the main actor so the block does not inherit main-actor
  /// isolation; it runs on `writes`, and Swift 6 traps on that mismatch.
  nonisolated private static func saveWork(
    _ records: [QuickDraftRecord], to directory: URL,
    onFailure: @escaping @MainActor @Sendable () -> Void
  ) -> DispatchWorkItem {
    DispatchWorkItem {
      do { try write(records, to: directory) } catch { Task { @MainActor in onFailure() } }
    }
  }

  nonisolated private static func write(_ records: [QuickDraftRecord], to directory: URL) throws {
    let data = try JSONEncoder().encode(Envelope(records: records))
    guard data.count <= 8 * 1024 * 1024 else {
      throw QuickDraftError.message("Draft storage is full.")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = directory.appendingPathComponent("drafts-v1.json")
    try data.write(to: file, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
