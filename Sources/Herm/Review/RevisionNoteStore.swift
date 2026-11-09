import Combine
import Foundation

/// User-authored excerpts have separate versioned recovery, never workspace snapshots.
@MainActor
final class RevisionNoteStore: ObservableObject {
    @Published var notes: [RevisionNote] = [] { didSet { scheduleSave() } }
    @Published private(set) var sources: [String: String] = [:]
    @Published private(set) var error: String?
    private let file: URL?
    private var writable = true
    private let writes = DispatchQueue(label: "herm.revision-drafts.writer")
    private var pending: DispatchWorkItem?
    private struct Envelope: Codable {
        var version = 1
        let notes: [RevisionNote]
    }

    init(file: URL? = nil) {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1024 * 1024 else {
                throw QuickDraftError.message("Oversized recovery")
            }
            let recovered = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
            guard recovered.version == 1 else { throw QuickDraftError.message("Unknown recovery version") }
            notes = recovered.notes
        } catch {
            writable = false
            self.error =
                "Revision-note recovery could not be read. The original file is preserved; keep new notes in Herm until recovery is repaired."
        }
    }
    func register(path: String, identity: String) { if sources[path] != identity { sources[path] = identity } }
    func invalidateSources() { sources = [:] }
    func isStale(_ note: RevisionNote) -> Bool { sources[note.path] != note.documentID }
    var prompt: String {
        notes.map { $0.context(currentIdentity: sources[$0.path] ?? "unverified").body }.joined(separator: "\n\n")
    }

    /// One chat attachment for every note; the caller clears the notes once it is attached.
    func chatContext(repository: String, projectPath: String?) -> ChatContext {
        ChatContext(
            id: UUID().uuidString, title: notes.count == 1 ? "1 revision note" : "\(notes.count) revision notes",
            body: "Please revise the selected code using these review notes.\nRepository: \(repository)\n\n\(prompt)",
            projectPath: projectPath)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard writable, let file else { return }
        let snapshot = notes
        do {
            try writes.sync { try Self.write(snapshot, file: file) }
            error = nil
        } catch { self.error = "Revision notes could not be saved. Keep Herm open and check storage access." }
    }
    private func scheduleSave() {
        pending?.cancel()
        guard writable, let file else { return }
        let snapshot = notes
        let item = Self.saveWork(snapshot, file: file) { [weak self] in
            self?.error = "Revision notes could not be saved. Keep Herm open and check storage access."
        }
        pending = item
        writes.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }
    nonisolated private static func saveWork(
        _ notes: [RevisionNote], file: URL, failed: @escaping @MainActor @Sendable () -> Void
    ) -> DispatchWorkItem {
        DispatchWorkItem { do { try write(notes, file: file) } catch { Task { @MainActor in failed() } } }
    }
    nonisolated private static func write(_ notes: [RevisionNote], file: URL) throws {
        let data = try JSONEncoder().encode(Envelope(notes: notes))
        guard data.count <= 16 * 1024 * 1024 else { throw QuickDraftError.message("Revision-note storage is full.") }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
