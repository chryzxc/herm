import CryptoKit
import Foundation

@MainActor
final class ReviewDraftStore {
    static let shared = ReviewDraftStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Herm/ReviewDrafts"))
    private let directory: URL?
    private var stores: [String: RevisionNoteStore] = [:]
    init(directory: URL? = nil) { self.directory = directory }
    func notes(key: String) -> RevisionNoteStore {
        if let existing = stores[key] { return existing }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        let created = RevisionNoteStore(file: directory?.appendingPathComponent(name))
        stores[key] = created
        return created
    }
    func flush() { stores.values.forEach { $0.flush() } }
}
