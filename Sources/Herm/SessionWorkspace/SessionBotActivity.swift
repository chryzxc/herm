import Foundation

/// A Dock-owned, session-scoped projection of an explicitly dispatched Bot
/// request. It is deliberately independent of Kanban cards and Bot liveness.
enum BotActivityState: String, CaseIterable, Hashable, Sendable, Codable {
    case queued, working, waiting, completed, failed, canceled

    var label: String { rawValue.capitalized }
}

struct BotActivityRecord: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let originSessionID: String
    let botID: String
    let botName: String
    let summary: String
    var state: BotActivityState
    let createdAt: Date
    var updatedAt: Date
    var result: String?
    var linkedCardID: String?
    var botChatSessionID: String?
    /// Hermes background process running a Bot DM (`proc_…`); its completion
    /// notice carries the Bot's reply and session.
    var processID: String?

    init(id: String = UUID().uuidString, originSessionID: String, botID: String, botName: String, summary: String, state: BotActivityState = .queued, createdAt: Date = Date(), updatedAt: Date = Date(), result: String? = nil, linkedCardID: String? = nil, botChatSessionID: String? = nil) {
        self.id = id
        self.originSessionID = originSessionID
        self.botID = botID
        self.botName = botName
        self.summary = summary
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.result = result
        self.linkedCardID = linkedCardID
        self.botChatSessionID = botChatSessionID
    }
}

extension BotActivityRecord {
    /// A durable exact card reference captured from trusted Hermes tool
    /// activity. It is lookup evidence, not a fabricated Bot task row.
    var isKanbanReference: Bool { botID == "kanban-reference" && linkedCardID != nil }
}

private struct BotActivityArchive: Codable {
    let schemaVersion: Int
    let recordsBySessionID: [String: [BotActivityRecord]]

    init(recordsBySessionID: [String: [BotActivityRecord]]) {
        schemaVersion = 1
        self.recordsBySessionID = recordsBySessionID
    }
}

struct BotActivityStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.fileURL = fileURL ?? supportRoot
            .appendingPathComponent("Herm", isDirectory: true)
            .appendingPathComponent("session-bot-activity-v1.json")
    }

    func load() -> [String: [BotActivityRecord]] {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? Self.decoder.decode(BotActivityArchive.self, from: data),
              archive.schemaVersion == 1 else { return [:] }
        return archive.recordsBySessionID.filter { !$0.key.isEmpty }
    }

    func encoded(_ recordsBySessionID: [String: [BotActivityRecord]]) -> Data? {
        try? Self.encoder.encode(BotActivityArchive(recordsBySessionID: recordsBySessionID))
    }

    func saveEncoded(_ data: Data) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("[Herm] bot activity persistence failed")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

actor BotActivityWriter {
    private let store: BotActivityStore
    private var pending: [String: [BotActivityRecord]]?
    private var generation = 0
    private var lastEncoded: Data?

    init(store: BotActivityStore) { self.store = store }

    func enqueue(_ recordsBySessionID: [String: [BotActivityRecord]]) {
        pending = recordsBySessionID
        generation &+= 1
        let expected = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.commitIfCurrent(expected)
        }
    }

    func flush() {
        generation &+= 1
        commit()
    }

    private func commitIfCurrent(_ expected: Int) {
        guard expected == generation else { return }
        commit()
    }

    private func commit() {
        guard let pending, let data = store.encoded(pending), data != lastEncoded else { return }
        lastEncoded = data
        store.saveEncoded(data)
        self.pending = nil
    }
}

enum SessionBotActivityPresentation {
    struct Snapshot: Equatable {
        let list: [BotActivityRecord]
        let kanban: [BotActivityState: [BotActivityRecord]]
        let emptyMessage: String
    }

    static func snapshot(records: [BotActivityRecord], sessionID: String?) -> Snapshot {
        snapshot(records: records, sessionIDs: [sessionID])
    }

    static func snapshot(records: [BotActivityRecord], sessionIDs: [String?]) -> Snapshot {
        let ids = Set(sessionIDs.compactMap { $0 }.filter { !$0.isEmpty })
        let scoped = records
            .filter { ids.contains($0.originSessionID) && !$0.isKanbanReference }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id > $1.id
            }
        var columns: [BotActivityState: [BotActivityRecord]] = [:]
        for state in BotActivityState.allCases { columns[state] = scoped.filter { $0.state == state } }
        return Snapshot(list: scoped, kanban: columns, emptyMessage: "No bot work in this session yet.")
    }

    static func state(forKanbanStatus status: String) -> BotActivityState {
        switch status.lowercased() {
        case "ready", "todo", "queued": .queued
        case "running", "claimed", "in_progress": .working
        case "blocked", "review", "waiting": .waiting
        case "done", "completed": .completed
        case "failed", "timed_out", "gave_up": .failed
        case "canceled", "cancelled", "archived": .canceled
        default: .waiting
        }
    }
}
